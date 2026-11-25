import Darwin
import Foundation

/// Move an idle installation to private recovery before deleting its individually
/// lockfile-listed packages. The package manager can rebuild the install independently of
/// the packages that were kept.
struct InstalledPackageCleanup: Sendable {
    let ids: [Int]
    let bytes: Int64
    let recovery: URL
    private let isNpx: Bool

    private struct Inventory: Decodable {
        struct Package: Decodable { let integrity: String? }
        let packages: [String: Package]
    }

    static func prepare(node: DiskNode, scan: ScanResult, home: String, exclusions: [String]) throws -> Self? {
        let modules = scan.url(for: node.id)
        let entry = modules.deletingLastPathComponent()
        let isNpx = GitWorktreeManager.systemAliases(entry.deletingLastPathComponent().standardizedFileURL.path) == GitWorktreeManager.systemAliases(URL(fileURLWithPath: home).appendingPathComponent(".npm/_npx").path)
        let skipped = (scan.incompleteEvidence ?? []).filter { $0.path.hasPrefix(modules.path + "/") }
        guard scan.incompleteEvidenceTruncated != true, !skipped.isEmpty,
              skipped.allSatisfy({ evidence in
                  let name = URL(fileURLWithPath: evidence.path).lastPathComponent.lowercased()
                  var file = stat()
                  return evidence.reason == "excluded by sensitive path policy"
                      && name.range(of: #"^(credentials?|secrets?)(\.[a-z0-9_-]+)*\.(js|ts|mjs|cjs|jsx|tsx)(\.map)?$"#, options: .regularExpression) != nil
                      && lstat(evidence.path, &file) == 0 && file.st_mode & S_IFMT == S_IFREG
              }) else { return nil }
        var verified = Set<String>(), ids: [Int] = []
        let policy = FolderExclusions(paths: exclusions)
        let recovery = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/StorageDaddy/Cleanup Recovery")
            .appendingPathComponent((isNpx ? "npx-" : "project-") + UUID().uuidString)
        guard !policy.blocksCleanup(recovery), !policy.blocksCleanup(modules) else { return nil }

        func include(_ id: Int, name: String, integrity: String?) {
            let package = scan.nodes[id]
            guard package.isDirectory, !package.isSymlink, package.isScanIncomplete != true,
                  let integrity, let separator = integrity.firstIndex(of: "-"),
                  let length = ["sha1": 20, "sha256": 32, "sha384": 48, "sha512": 64][String(integrity[..<separator])],
                  Data(base64Encoded: String(integrity[integrity.index(after: separator)...]))?.count == length,
                  package.children.contains(where: {
                      let child = scan.nodes[$0]
                      return child.name == "package.json" && !child.isDirectory && !child.isSymlink
                  }) else { return }
            ids.append(id)
            verified.insert(name)
        }

        if let data = readMetadata(modules.appendingPathComponent(".package-lock.json")),
           let inventory = try? JSONDecoder().decode(Inventory.self, from: data) {
            let rootInventory: Inventory?
            if isNpx { rootInventory = nil }
            else {
                guard let lock = readMetadata(entry.appendingPathComponent("package-lock.json")),
                      let declared = try? JSONDecoder().decode(Inventory.self, from: lock) else { return nil }
                rootInventory = declared
            }
            func includeNpm(_ id: Int, _ name: String) {
                let key = "node_modules/" + name
                let integrity = inventory.packages[key]?.integrity
                guard isNpx || rootInventory?.packages[key]?.integrity == integrity else { return }
                include(id, name: name, integrity: integrity)
            }
            for id in node.children {
                let child = scan.nodes[id]
                guard child.isDirectory, !child.isSymlink, !child.name.hasPrefix(".") else { continue }
                if child.name.hasPrefix("@") {
                    for pkg in child.children { includeNpm(pkg, child.name + "/" + scan.nodes[pkg].name) }
                } else { includeNpm(id, child.name) }
            }
            if isNpx, !(try NpxCacheReview.requestedPackages(entry: entry)).isSubset(of: verified) { return nil }
        } else if !isNpx, let store = node.children.map({ scan.nodes[$0] }).first(where: {
            $0.name == ".pnpm" && $0.isDirectory && !$0.isSymlink
        }), let lock = readMetadata(entry.appendingPathComponent("pnpm-lock.yaml")),
              readMetadata(modules.appendingPathComponent(".pnpm/lock.yaml")) == lock,
              let text = String(data: lock, encoding: .utf8) {
            // Recognize the v9 lockfile's literal package keys and inline SRI. Other
            // YAML shapes, workspace links and entries without an integrity stay kept.
            let packages = pnpmPackages(text)
            for id in store.children {
                let slot = scan.nodes[id]
                guard slot.isDirectory, !slot.isSymlink,
                      let deps = slot.children.map({ scan.nodes[$0] }).first(where: {
                        $0.name == "node_modules" && $0.isDirectory && !$0.isSymlink
                      }) else { continue }
                func includePnpm(_ id: Int, _ name: String) {
                    let prefix = name.replacingOccurrences(of: "/", with: "+") + "@"
                    guard slot.name.hasPrefix(prefix) else { return }
                    let version = slot.name.dropFirst(prefix.count).prefix(while: { $0 != "_" && $0 != "(" })
                    let key = name + "@" + version
                    include(id, name: key, integrity: packages[key])
                }
                for childID in deps.children {
                    let child = scan.nodes[childID]
                    guard child.isDirectory, !child.isSymlink else { continue }
                    if child.name.hasPrefix("@") {
                        for pkg in child.children { includePnpm(pkg, child.name + "/" + scan.nodes[pkg].name) }
                    } else { includePnpm(childID, child.name) }
                }
            }
        }
        guard !ids.isEmpty else { return nil }
        return Self(ids: ids, bytes: ids.reduce(0) { $0 + scan.nodes[$1].allocatedBytes }, recovery: recovery, isNpx: isNpx)
    }

    private static func pnpmPackages(_ lock: String) -> [String: String] {
        var section = false, key: String?
        var packages: [String: String] = [:]
        for line in lock.split(separator: "\n") {
            if !line.hasPrefix(" ") {
                section = line == "packages:"
                key = nil
            } else if section && line.hasPrefix("  ") && !line.hasPrefix("   ") {
                key = line.hasSuffix(":") ? String(line.dropFirst(2).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) : nil
            } else if section, let key, line.hasPrefix("    resolution: {integrity: "), line.hasSuffix("}") {
                packages[key] = String(line.dropFirst("    resolution: {integrity: ".count).dropLast())
            }
        }
        return packages
    }

    private static func readMetadata(_ url: URL) -> Data? {
        guard GitWorktreeManager.systemAliases(url.standardizedFileURL.path) == GitWorktreeManager.systemAliases(url.resolvingSymlinksInPath().standardizedFileURL.path) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 4_194_304,
              let data = try? handle.read(upToCount: 4_194_305), data.count <= 4_194_304 else { return nil }
        return data
    }

    func clean(parent: DiskNode, scan: ScanResult, home: String, exclusions: [String], avoidance: [String]) async throws {
        let fm = FileManager.default
        let modules = scan.url(for: parent.id)
        let entry = modules.deletingLastPathComponent()
        let policy = FolderExclusions(paths: exclusions)
        let fresh = try await DiskScanner.scan(root: modules, excludedFolders: exclusions, promptAvoidanceFolders: avoidance)
        guard let root = fresh.nodes.first, root.device == parent.device, root.inode == parent.inode,
              !fresh.nodes.contains(where: { CleanupGuidance.isGitCheckoutMarker($0.name) }),
              !policy.blocksCleanup(recovery), !policy.blocksCleanup(modules),
              let current = try Self.prepare(node: root, scan: fresh, home: home, exclusions: exclusions),
              Set(current.ids.map { fresh.url(for: $0).path }) == Set(ids.map { scan.url(for: $0).path })
        else { throw CleanupPreflightError.changedRecord(path: modules.path) }
        try await CleanupPreflight.validate(ids: ids, in: scan, excludedFolders: exclusions, regenerableIDs: [],
            home: home, openFiles: nil, requireNoNestedGitCheckout: true, promptAvoidanceFolders: avoidance)
        if !isNpx {
            guard !FleetManagedCheckout.containsReservedProject(modules) else { throw CocoaError(.fileWriteNoPermission) }
            try DeveloperCleanupPlan.checkDependencyOwner(modules, openFiles: nil)
        }
        try CleanupActiveUse.validate(urls: [entry], home: home)
        try CleanupSafety.validate(url: modules, expected: parent, root: entry, allowingRegenerableChanges: true, home: home)
        try Task.checkCancellation()

        // Create the recovery path one component at a time. Never traverse a
        // symbolic link, replace an existing destination or copy across devices.
        let base = URL(fileURLWithPath: home).standardizedFileURL
        var directory = base
        for component in recovery.pathComponents.dropFirst(base.pathComponents.count) {
            directory.appendPathComponent(component)
            if mkdir(directory.path, 0o700) != 0 && (errno != EEXIST || directory.path == recovery.path) { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  UInt64(info.st_dev) == parent.device else { throw CocoaError(.fileWriteNoPermission) }
        }
        let kept = recovery.appendingPathComponent("node_modules")
        guard renamex_np(modules.path, kept.path, UInt32(RENAME_EXCL)) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = rmdir(recovery.path)
            throw failure
        }
        do {
            var info = stat()
            guard lstat(kept.path, &info) == 0, UInt64(info.st_ino) == parent.inode, UInt64(info.st_dev) == parent.device
            else { throw CleanupPreflightError.changedRecord(path: kept.path) }
            for id in ids {
                try Task.checkCancellation()
                let path = scan.url(for: id).path
                guard path.hasPrefix(modules.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
                let target = kept.appendingPathComponent(String(path.dropFirst(modules.path.count + 1)))
                try CleanupSafety.validate(url: target, expected: scan.nodes[id], root: kept)
                try fm.removeItem(at: target)
            }
        } catch {
            throw NSError(domain: "NpxCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Cleanup stopped (" + error.localizedDescription + "). Remaining packages are preserved at " + kept.path + "."])
        }
    }
}
