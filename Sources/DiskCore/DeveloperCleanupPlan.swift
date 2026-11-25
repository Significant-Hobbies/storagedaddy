import Foundation

/// A scoped cleanup review. The partial scan is never published as a Storage scan.
public struct DeveloperCleanupPlan: Sendable {
    public struct Item: Identifiable, Sendable {
        public let id: Int
        public let path: String
        public let allocatedBytes: Int64
        public let canDeletePermanently: Bool
        public let keptReason: String?
        public let recoveryPath: String?
        public let verifiedPackages: Int
        package let device: UInt64
        package let inode: UInt64
    }

    public struct Outcome: Sendable {
        public var deleted: Set<Int> = []
        public var trashed: Set<Int> = []
        public var kept: [Int: String] = [:]
        public var cancelled = false
    }

    public let id = UUID()
    public var rootPath: String { scan.rootPath }
    public var skipped: Int { scan.skipped }
    public let idleWorktrees: [GitWorktreeCandidate]
    public let items: [Item]
    private let scan: ScanResult
    private let exclusions: [String]
    private let promptAvoidanceFolders: [String]
    private let partialNpx: [Int: NpxPackageCleanup]
    private let quickCleanup: Bool
    private let home: String

    public static func prepare(root: URL, excluding exclusions: [String] = [],
                               promptAvoidanceFolders: [String] = [],
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path, quickCleanup: Bool = false) async throws -> Self {
        try Task.checkCancellation()
        var scope = root.resolvingSymlinksInPath().standardizedFileURL
        while !scope.path.isEmpty && scope.path != "/" {
            if CleanupGuidance.isDependencyContainerName(scope.lastPathComponent) {
                throw NSError(domain: "DeveloperCleanup", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Choose the project folder that contains node_modules to review its dependencies together."])
            }
            scope.deleteLastPathComponent()
        }
        let scan = try await DiskScanner.scan(root: root, excludedFolders: exclusions,
                                              promptAvoidanceFolders: promptAvoidanceFolders, developerArtifactHome: home, quickCleanup: quickCleanup)
        try Task.checkCancellation()
        if scan.nodes.isEmpty {
            let message = scan.incompleteEvidence?.first.map { "This folder was \($0.reason)." }
                ?? "This folder could not be scanned."
            throw NSError(domain: "DeveloperCleanup", code: 2, userInfo: [NSLocalizedDescriptionKey:
                message])
        }
        let exclusionPolicy = FolderExclusions(paths: exclusions)
        let candidates = scan.nodes.filter { $0.parent != nil && $0.isDirectory && !$0.isSymlink
            && (CleanupGuidance.isFocusedDeveloperName($0.name) || (quickCleanup && ["cache", "Intermediates.noindex"].contains($0.name))) }
        let npxRoot = URL(fileURLWithPath: home).appendingPathComponent(".npm/_npx").standardizedFileURL
        let isNpxScope = quickCleanup && root.standardizedFileURL.path == npxRoot.path
        let eligible = Dictionary(uniqueKeysWithValues: candidates.compactMap { node -> (Int, URL)? in
            let url = scan.url(for: node.id)
            if isNpxScope {
                let entry = url.deletingLastPathComponent()
                guard url.lastPathComponent == "node_modules", entry.deletingLastPathComponent().path == npxRoot.path,
                      entry.lastPathComponent.range(of: #"^[a-f0-9]{16}$"#, options: .regularExpression) != nil,
                      CleanupGuidance.isProjectDependencies(path: url.path) else { return nil }
                return (node.id, url)
            }
            if quickCleanup {
                return CleanupGuidance.isProjectDependencies(path: url.path) || CleanupGuidance.isQuickBuildCache(path: url.path) ? (node.id, url) : nil
            }
            return CleanupGuidance.isRegenerableFolder(path: url.path, home: home) ? (node.id, url) : nil
        })
        let roots = candidates.filter { node in
            guard eligible[node.id] != nil else { return false }
            return !ancestors(of: node.id, in: scan).contains { eligible[$0] != nil }
        }
        let rootIDs = Set(roots.map(\.id))
        let repositories = Set(scan.nodes.lazy.filter { CleanupGuidance.isGitCheckoutMarker($0.name) }
            .flatMap { ancestors(of: $0.id, in: scan).filter(rootIDs.contains) })
        let managedRetired = FleetManagedCheckout.registry(home: URL(fileURLWithPath: home)).appendingPathComponent("retired")
        let linked = quickCleanup && !isNpxScope && root.standardizedFileURL.path != managedRetired.path
            ? try GitWorktreeManager.linkedCandidates(in: scan, excluding: rootIDs, exclusions: exclusionPolicy) : []
        let openFiles = try captureOpenFiles(linked.map { $0.url.path } + roots.compactMap { eligible[$0.id] }.flatMap { url in
            [url.path, CleanupActiveUse.metroProject(for: url)?.path, quickCleanup ? url.deletingLastPathComponent().path : nil].compactMap { $0 }
        })

        let idle = linked.filter { openFiles?.user(of: $0.url.path) == nil && !FleetManagedCheckout.isReserved($0.url) }
        let measuredWorktrees = try GitWorktreeManager.measure(idle)
        let npxProcesses = isNpxScope && !roots.isEmpty ? try CleanupActiveUse.npxProcessSnapshot() : nil
        var partialNpx: [Int: NpxPackageCleanup] = [:]
        var items: [Item] = []
        for node in roots {
            try Task.checkCancellation()
            guard let url = eligible[node.id] else { continue }
            let reason: String?
            do {
                if quickCleanup && FleetManagedCheckout.containsReservedProject(url) {
                    throw DiskAnalysisError.unsafePath(path: url.path, reason: "Fleet has an active registration or an uncleared lease for this workspace.")
                }
                if quickCleanup && !isNpxScope && CleanupGuidance.isProjectDependencies(path: url.path) {
                    try Self.checkDependencyOwner(url, openFiles: openFiles)
                }
                if let npxProcesses {
                    if let owner = openFiles?.user(of: url.deletingLastPathComponent().path) {
                        throw DiskAnalysisError.unsafePath(path: url.path, reason: "npx entry in use by " + owner)
                    }
                    try NpxCacheReview.validate(entries: [url.deletingLastPathComponent()], processOutput: npxProcesses)
                }
                try ToolStorage.validateCleanup(path: url.path)
                if exclusionPolicy.blocksCleanup(url) { throw CleanupPreflightError.excludedFolder(url.path) }
                try CleanupSafety.validate(url: url, expected: node, root: URL(fileURLWithPath: scan.rootPath),
                                           allowingRegenerableChanges: !(quickCleanup && CleanupGuidance.isQuickBuildCache(path: url.path)), home: home)
                if let cleaner = CleanupGuidance.requiredNativeCleaner(path: url.path, home: home) {
                    reason = "Use \(cleaner) in Developer Insights. The cache manager owns its lock."
                } else if CleanupGuidance.isSuggestedCache(category: .packageCaches, path: url.path, home: home)
                            || node.name == "_cacache" {
                    reason = "Use the package manager’s cache cleaner to remove this cache."
                } else if CleanupGuidance.isSuggestedCache(category: .modelCaches, path: url.path, home: home) {
                    reason = "Review these downloaded models in Developer Insights before removing them."
                } else if node.isScanIncomplete == true {
                    if isNpxScope, !repositories.contains(node.id), openFiles?.user(of: url.path) == nil,
                       let partial = try NpxPackageCleanup.prepare(node: node, scan: scan, home: home, exclusions: exclusions) {
                        partialNpx[node.id] = partial
                        reason = nil
                    } else { reason = "Some contents could not be checked. This folder is kept." }
                }
                else if repositories.contains(node.id), quickCleanup || ["node_modules", ".metro-cache"].contains(node.name) {
                    reason = "Contains a Git checkout. This folder is kept."
                } else if !FileManager.default.isDeletableFile(atPath: url.path) {
                    reason = "macOS does not allow removal with the current permissions."
                } else if let user = openFiles?.user(of: url.path) { reason = "In use by \(user). Quit it and scan again." }
                else if quickCleanup, CleanupGuidance.isQuickBuildCache(path: url.path),
                        let user = openFiles?.user(of: url.deletingLastPathComponent().path) { reason = "Build output in use by \(user). Scan again when it finishes." }
                else if let project = CleanupActiveUse.metroProject(for: url), let user = openFiles?.user(of: project.path) {
                    reason = "Metro project in use by \(user). Quit it and scan again."
                }
                else { reason = nil }
            } catch { reason = error.localizedDescription }
            items.append(Item(id: node.id, path: url.path, allocatedBytes: partialNpx[node.id]?.bytes ?? node.allocatedBytes,
                              canDeletePermanently: (quickCleanup && CleanupGuidance.isQuickBuildCache(path: url.path)) || CleanupGuidance.canDeletePermanently(path: url.path, home: home),
                              keptReason: reason, recoveryPath: partialNpx[node.id]?.recovery.path, verifiedPackages: partialNpx[node.id]?.ids.count ?? 0, device: node.device, inode: node.inode))
        }
        return Self(idleWorktrees: measuredWorktrees, items: items.sorted {
            if ($0.keptReason == nil) != ($1.keptReason == nil) { return $0.keptReason == nil }
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path < $1.path
        }, scan: scan, exclusions: exclusions, promptAvoidanceFolders: promptAvoidanceFolders, partialNpx: partialNpx, quickCleanup: quickCleanup, home: home)
    }

    public func clean(ids: Set<Int>, permanently: Bool,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Outcome {
        let selected = items.filter { ids.contains($0.id) && $0.keptReason == nil }
        var outcome = Outcome()
        guard selected.count == ids.count else { return outcome }
        let dependencies = selected.filter { CleanupGuidance.isProjectDependencies(path: $0.path) }.flatMap {
            quickCleanup ? [$0.path, URL(fileURLWithPath: $0.path).deletingLastPathComponent().path] : [$0.path]
        }
        var openFiles: CleanupActiveUse.OpenFiles?
        let root = URL(fileURLWithPath: scan.rootPath)
        let policy = FolderExclusions(paths: exclusions)
        for (index, item) in selected.enumerated() {
            do {
                try Task.checkCancellation()
                progress?(index + 1, selected.count)
                let url = URL(fileURLWithPath: item.path)
                if let partial = partialNpx[item.id] {
                    guard permanently else { throw CocoaError(.fileWriteNoPermission) }
                    try await partial.clean(parent: scan.nodes[item.id], scan: scan, home: home,
                                            exclusions: exclusions, avoidance: promptAvoidanceFolders)
                    outcome.deleted.insert(item.id)
                    continue
                }
                let isDependencies = CleanupGuidance.isProjectDependencies(path: item.path)
                if isDependencies, openFiles?.isFresh != true {
                    openFiles = try Self.captureOpenFiles(dependencies)
                }
                try await CleanupPreflight.validate(ids: [item.id], in: scan, excludedFolders: exclusions,
                    regenerableIDs: [item.id], home: home, openFiles: isDependencies ? openFiles : nil,
                    requireNoNestedGitCheckout: quickCleanup || ["node_modules", ".metro-cache"].contains(url.lastPathComponent),
                    promptAvoidanceFolders: promptAvoidanceFolders)
                try Task.checkCancellation()
                if policy.blocksCleanup(url) { throw CleanupPreflightError.excludedFolder(url.path) }
                if CleanupActiveUse.metroProject(for: url) != nil,
                   !CleanupGuidance.isRegenerableFolder(path: url.path, home: home) {
                    throw CleanupPreflightError.changedRecord(path: url.path)
                }
                try CleanupSafety.validate(url: url, expected: scan.nodes[item.id], root: root,
                                           allowingRegenerableChanges: !(quickCleanup && CleanupGuidance.isQuickBuildCache(path: url.path)), home: home)
                if quickCleanup && CleanupGuidance.isQuickBuildCache(path: url.path) {
                    try CleanupActiveUse.validate(urls: [url.deletingLastPathComponent()], home: home)
                }
                if quickCleanup && FleetManagedCheckout.containsReservedProject(url) {
                    throw DiskAnalysisError.unsafePath(path: url.path, reason: "Fleet has an active registration or an uncleared lease for this workspace.")
                }
                if quickCleanup && isDependencies && !url.path.hasPrefix(URL(fileURLWithPath: home).appendingPathComponent(".npm/_npx").path + "/") {
                    try Self.checkDependencyOwner(url, openFiles: openFiles?.isFresh == true ? openFiles : nil)
                }
                if permanently && item.canDeletePermanently {
                    guard (quickCleanup && CleanupGuidance.isQuickBuildCache(path: url.path)) || CleanupGuidance.canDeletePermanently(path: url.path, home: home),
                          CleanupGuidance.requiredNativeCleaner(path: url.path, home: home) == nil else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    do { try FileManager.default.removeItem(at: url) }
                    catch {
                        throw NSError(domain: "DeveloperCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "Permanent deletion did not finish. Some contents may have been removed. \(error.localizedDescription)"])
                    }
                    outcome.deleted.insert(item.id)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    outcome.trashed.insert(item.id)
                }
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch { outcome.kept[item.id] = error.localizedDescription }
        }
        return outcome
    }

    private static func checkDependencyOwner(_ url: URL, openFiles: CleanupActiveUse.OpenFiles?) throws {
        let project = url.deletingLastPathComponent()
        let evidence = try openFiles ?? CleanupActiveUse.captureOpenFiles(for: [project.path])
        if let user = evidence.user(of: project.path) {
            throw GitWorktreeError.unsafe("Project in use by " + user + ".")
        }
        var ancestor = project
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                guard GitCheckoutProbe.runLocal(at: project, arguments: ["--no-lazy-fetch", "ls-files", "--cached", "-z", "--", "node_modules"]) == "" else {
                    throw GitWorktreeError.unsafe("Dependencies are tracked by Git or the index could not be checked.")
                }
                break
            }
            ancestor.deleteLastPathComponent()
        }
    }

    private static func captureOpenFiles(_ paths: [String]) throws -> CleanupActiveUse.OpenFiles? {
        try Task.checkCancellation()
        return paths.isEmpty ? nil : try CleanupActiveUse.captureOpenFiles(for: paths)
    }

    private static func ancestors(of id: Int, in scan: ScanResult) -> [Int] {
        var result: [Int] = []
        var parent = scan.nodes[id].parent
        while let id = parent {
            result.append(id)
            parent = scan.nodes[id].parent
        }
        return result
    }
}
