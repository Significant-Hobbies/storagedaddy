import Darwin
import Foundation
import Security

/// Individually reviewed generated folders. A candidate retains the inventory
/// the user saw, so confirmation can detect changes throughout the folder.
public struct GeneratedCacheCandidate: Sendable {
    fileprivate enum Kind: Sendable {
        case chromium(ChromiumDisposableCache)
        case chrome(store: URL)
        case xcode(derivedData: URL, workspace: URL)
        case metro(project: URL)
    }

    public let url: URL
    public let title: String
    public var allocatedBytes: Int64 { scan.nodes[0].allocatedBytes }
    public var device: UInt64 { scan.nodes[0].device }
    public var inode: UInt64 { scan.nodes[0].inode }
    private let kind: Kind
    private let scan: ScanResult
    private let originalExclusions: [String]

    private static let xcodeCaches = ["Build/Intermediates.noindex", "ModuleCache.noindex",
        "SDKStatCaches.noindex", "CompilationCache.noindex", "SDKExplicitPrecompiledModules", "Index.noindex"]

    public static func discover(home: URL, excludedFolders: [String]) async throws -> [Self] {
        // System temporary caches belong only to the currently logged-in user's inventory.
        guard home.resolvingSymlinksInPath().path == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path else {
            return try await discover(home: home, temporary: nil, chromeStore: nil, excludedFolders: excludedFolders)
        }
        let temporary = physicalPath(FileManager.default.temporaryDirectory).map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let store = temporary.deletingLastPathComponent().appendingPathComponent("X/com.google.Chrome.code_sign_clone")
        return try await discover(home: home, temporary: URL(fileURLWithPath: "/private/tmp"),
            chromeStore: ChromeSigningClones.location(path: store.path) == .store ? store : nil, excludedFolders: excludedFolders)
    }

    static func discover(home: URL, temporary: URL?, chromeStore: URL?, excludedFolders: [String]) async throws -> [Self] {
        let policy = FolderExclusions(paths: excludedFolders)
        var locations: [URL: Kind] = [:]
        func children(_ root: URL) -> [URL] {
            guard !policy.contains(root.path), !isSensitivePath(root), physicalDirectory(root) else { return [] }
            return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        }
        func derivedData(_ base: URL) {
            guard !policy.contains(base.path), let workspace = workspaceOfDerivedData(base),
                  !policy.contains(workspace.path) else { return }
            for name in xcodeCaches {
                let url = base.appendingPathComponent(name)
                if !policy.blocksCleanup(url), physicalDirectory(url, owned: true), untrackedIfInCheckout(url) {
                    locations[url] = .xcode(derivedData: base, workspace: workspace)
                }
            }
        }
        func metro(_ project: URL) {
            let url = project.appendingPathComponent(".metro-cache")
            if !policy.blocksCleanup(url), physicalDirectory(url, owned: true), !isSensitivePath(url),
               CleanupGuidance.isRegenerableFolder(path: url.path), untrackedIfInCheckout(url) {
                locations[url] = .metro(project: project)
            }
        }

        for child in children(home.appendingPathComponent("Library/Developer/Xcode/DerivedData")) {
            try Task.checkCancellation()
            derivedData(child)
        }
        for child in children(home.appendingPathComponent("Library/Developer/XcodeBuildMCP/workspaces")) {
            try Task.checkCancellation()
            derivedData(child.appendingPathComponent("DerivedData"))
        }
        for child in temporary.map(children) ?? [] {
            try Task.checkCancellation()
            guard physicalDirectory(child, owned: true), !policy.contains(child.path), !isSensitivePath(child),
                  child.pathExtension != "app" else { continue }
            derivedData(child)
            derivedData(child.appendingPathComponent("DerivedData"))
            derivedData(child.appendingPathComponent("build"))
            metro(child)
            // mkdtemp-style scratch directories can contain multiple project checkouts.
            if child.lastPathComponent.range(of: #"\.[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil {
                for project in children(child) { metro(project) }
            }
        }
        for cache in ChromiumDisposableCache.locations(home: home, policy: policy) { locations[cache.url] = .chromium(cache) }
        if let chromeStore, !policy.contains(chromeStore.path) {
            for url in staleCopies(in: chromeStore) where !policy.blocksCleanup(url) {
                locations[url] = .chrome(store: chromeStore)
            }
        }
        guard !locations.isEmpty else { return [] }
        let paths = Set(locations.flatMap { useScopes($0.key, $0.value).map(\.path) })
        let open = try CleanupActiveUse.captureOpenFiles(for: Array(paths))
        var ready: [Self] = []
        for (url, kind) in locations.sorted(by: { $0.key.path < $1.key.path }) {
            try Task.checkCancellation()
            do {
                guard useScopes(url, kind).allSatisfy({ open.user(of: $0.path) == nil }) else { continue }
                try verifyLocation(url, kind, policy: policy)
                let scan = try await DiskScanner.scan(root: url, excludedFolders: excludedFolders)
                guard scan.nodes.first?.allocatedBytes ?? 0 > 0, approvedInventory(scan, kind: kind, at: url) else { continue }
                let title: String
                switch kind {
                case .chromium(let cache): title = cache.application + (url.lastPathComponent == "Cache_Data" ? " · HTTP cache" : " · JavaScript and WebAssembly code cache")
                case .chrome: title = "Chrome signing copy"
                case .xcode(_, let workspace): title = workspace.deletingPathExtension().lastPathComponent + " · " + url.lastPathComponent
                case .metro(let project): title = project.lastPathComponent + " · Metro transform cache"
                }
                ready.append(Self(url: url, title: title, kind: kind, scan: scan, originalExclusions: excludedFolders))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return ready
    }

    public func clean(excludedFolders: [String]) async throws {
        let exclusions = originalExclusions + excludedFolders
        let policy = FolderExclusions(paths: exclusions)
        try Self.verifyLocation(url, kind, policy: policy)
        try CleanupActiveUse.validate(urls: Self.useScopes(url, kind))
        try Task.checkCancellation()
        var state = stat()
        guard lstat(url.path, &state) == 0, UInt64(state.st_ino) == inode, UInt64(state.st_dev) == device,
              Date(timeIntervalSince1970: Double(state.st_mtimespec.tv_sec) + Double(state.st_mtimespec.tv_nsec) / 1_000_000_000) == scan.nodes[0].modified,
              state.st_mode & S_IFMT == S_IFDIR else { throw CleanupPreflightError.changedRecord(path: url.path) }

        // Claim the exact reviewed name atomically so a tool rebuilding a new
        // cache at the original path cannot lose its replacement.
        let staged = url.deletingLastPathComponent().appendingPathComponent("StorageDaddy interrupted cleanup " + UUID().uuidString)
        guard renamex_np(url.path, staged.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            // The inventory compares relative paths, inode, type, date and file
            // size. Sensitive names and unreadable or mounted contents fail closed.
            let fresh = try await DiskScanner.scan(root: staged, excludedFolders: exclusions)
            guard Self.approvedInventory(fresh, kind: kind, at: url) else { throw CleanupPreflightError.changedRecord(path: url.path) }
            try CleanupPreflight.validateUnchangedTree(reviewed: scan, current: fresh)
            try CleanupActiveUse.validate(urls: Self.useScopes(url, kind) + [staged])
            try Task.checkCancellation()
        } catch {
            guard renamex_np(staged.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                throw DiskAnalysisError.unsafePath(path: staged.path, reason: "Cleanup stopped. Remaining files are kept here because their original path is occupied or unavailable.")
            }
            throw error
        }
        do { try FileManager.default.removeItem(at: staged) }
        catch {
            throw DiskAnalysisError.unsafePath(path: staged.path, reason: "Cleanup was interrupted. Remaining files are kept here.")
        }
    }

    private static func verifyLocation(_ url: URL, _ kind: Kind, policy: FolderExclusions) throws {
        guard !policy.blocksCleanup(url), !isSensitivePath(url), physicalDirectory(url, owned: true),
              !FleetManagedCheckout.containsReservedProject(url) else { throw CleanupPreflightError.changedRecord(path: url.path) }
        switch kind {
        case .chromium: break // Immutable candidate records bind the exact recognized cache leaf.
        case .chrome(let store):
            guard staleCopies(in: store).contains(url), let bundle = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil).first, verifiedChrome(bundle) else {
                throw CleanupPreflightError.changedRecord(path: url.path)
            }
            // Each candidate gets an individual open-file check and the same
            // kernel-level in-use check as the existing signing-copy review.
            try ChromeSigningClones.validateCopy(at: url, now: Date(), chromeIsRunning: { false })
        case .xcode(let base, let workspace):
            guard workspaceOfDerivedData(base) == workspace, !policy.contains(workspace.path),
                  !FleetManagedCheckout.containsReservedProject(workspace),
                  xcodeCaches.contains(where: { base.appendingPathComponent($0).path == url.path }),
                  untrackedIfInCheckout(url) else { throw CleanupPreflightError.changedRecord(path: url.path) }
        case .metro(let owner):
            guard url.path == owner.appendingPathComponent(".metro-cache").path,
                  CleanupGuidance.isRegenerableFolder(path: url.path), untrackedIfInCheckout(url)
            else { throw CleanupPreflightError.changedRecord(path: url.path) }
        }
    }

    private static func approvedInventory(_ scan: ScanResult, kind: Kind, at url: URL) -> Bool {
        guard let root = scan.nodes.first, root.isDirectory, !root.isSymlink, root.isScanIncomplete != true,
              scan.errors.isEmpty, scan.skipped == 0 else { return false }
        for node in scan.nodes.dropFirst() {
            guard node.device == root.device, !CleanupGuidance.isGitCheckoutMarker(node.name) else { return false }
            if case .xcode = kind, node.parent == 0 {
                let allowed: Bool
                switch url.lastPathComponent {
                case "Intermediates.noindex":
                    allowed = node.isDirectory && (node.name.hasSuffix(".build") ||
                        ["XCBuildData", "EagerLinkingTBDs", "ExplicitPrecompiledModules", "SwiftExplicitPrecompiledModules",
                         "PrecompiledHeaders", "GeneratedModuleMaps", "UninstalledProducts"].contains(node.name))
                case "Index.noindex": allowed = node.isDirectory && node.name == "DataStore"
                case "CompilationCache.noindex": allowed = node.isDirectory && node.name == "generic"
                case "SDKStatCaches.noindex": allowed = !node.isDirectory && node.name.hasSuffix(".sdkstatcache")
                case "SDKExplicitPrecompiledModules":
                    allowed = !node.isDirectory && (node.name.hasSuffix(".pcm") || node.name.hasSuffix(".swiftmodule"))
                case "ModuleCache.noindex":
                    allowed = node.isDirectory ? node.name.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) != nil :
                        node.name.hasSuffix(".pcm") || node.name.hasSuffix(".swiftmodule") || node.name == "modules.timestamp" || node.name == "Session.modulevalidation"
                default: allowed = false
                }
                guard allowed, !node.isSymlink else { return false }
            }
            if case .metro = kind {
                // metro-file-map stores transforms under two-character hex buckets.
                let hex = node.name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                guard hex, !node.isSymlink else { return false }
                if node.isDirectory {
                    guard node.parent == 0, node.name.count == 2 else { return false }
                } else {
                    guard let parent = node.parent, parent > 0, scan.nodes[parent].parent == 0,
                          (30...128).contains(node.name.count) else { return false }
                }
            }
        }
        if case .chromium(let cache) = kind { return cache.accepts(scan) }
        return true
    }

    private static func workspaceOfDerivedData(_ base: URL) -> URL? {
        guard physicalDirectory(base, owned: true), !isSensitivePath(base) else { return nil }
        let plist = base.appendingPathComponent("info.plist")
        let fd = open(plist.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size < 65_536,
              let data = try? handle.read(upToCount: 65_536), data.count < 65_536,
              let metadata = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              metadata["LastAccessedDate"] is Date, let path = metadata["WorkspacePath"] as? String,
              path.hasPrefix("/") else { return nil }
        let workspace = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["xcworkspace", "xcodeproj"].contains(workspace.pathExtension), !isSensitivePath(workspace) else { return nil }
        let marker = workspace.pathExtension == "xcworkspace" ? "contents.xcworkspacedata" : "project.pbxproj"
        func regular(_ url: URL) -> Bool {
            var metadata = stat()
            return lstat(url.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
        }
        guard regular(workspace.appendingPathComponent(marker)) ||
                regular(base.appendingPathComponent("Logs/Build/LogStoreManifest.plist")) else { return nil }
        return workspace
    }

    private static func untrackedIfInCheckout(_ url: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            var info = stat()
            if lstat(parent.appendingPathComponent(".git").path, &info) == 0 {
                return GitCheckoutProbe.runLocal(at: parent, arguments: ["check-ignore", "-q", "--", url.path]) == "" &&
                    GitCheckoutProbe.runLocal(at: parent, arguments: ["--no-lazy-fetch", "ls-files", "--cached", "-z", "--", url.path]) == ""
            }
            guard errno == ENOENT else { return false }
            parent.deleteLastPathComponent()
        }
        return true
    }

    static func physicalDirectory(_ url: URL, owned: Bool = false) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
            (!owned || info.st_uid == getuid()) && physicalPath(url) == url.path
    }

    private static func physicalPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    private static func useScopes(_ url: URL, _ kind: Kind) -> [URL] {
        switch kind {
        case .chromium(let cache): return cache.owners + [url]
        case .chrome: return [url]
        case .xcode(let base, let workspace): return [base, workspace.deletingLastPathComponent()]
        case .metro(let owner): return [owner]
        }
    }

    private static func staleCopies(in store: URL) -> [URL] {
        guard physicalDirectory(store, owned: true) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        let copies = names.filter(ChromeSigningClones.isCopyName).compactMap { name -> (URL, TimeInterval)? in
            let url = store.appendingPathComponent(name)
            var info = stat()
            guard physicalDirectory(url, owned: true), lstat(url.path, &info) == 0 else { return nil }
            return (url, Double(info.st_mtimespec.tv_sec))
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }
        return copies.dropFirst(2).filter { Date().timeIntervalSince1970 - $0.1 >= 86_400 }.map(\.0)
    }

    private static func verifiedChrome(_ bundle: URL) -> Bool {
        guard ["Google Chrome.app.bundle", "Google Chrome.app"].contains(bundle.lastPathComponent),
              physicalDirectory(bundle, owned: true) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = #"anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        // Chrome updates can leave multiple signed framework versions in one
        // clone. Strict bundle-layout validation rejects these genuine copies.
        // Deep offline validation checks the nested code and sealed resources.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | SecCSFlags.noNetworkAccess.rawValue)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
