import Foundation

/// A scoped cleanup review. The partial scan is never published as a Storage scan.
public struct DeveloperCleanupPlan: Sendable {
    public struct Item: Identifiable, Sendable {
        public let id: Int
        public let path: String
        public let allocatedBytes: Int64
        public let canDeletePermanently: Bool
        public let keptReason: String?
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
    public let items: [Item]
    private let scan: ScanResult
    private let exclusions: [String]
    private let home: String

    public static func prepare(root: URL, excluding exclusions: [String] = [],
                               promptAvoidanceFolders: [String] = [],
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path) async throws -> Self {
        let scan = try await DiskScanner.scan(root: root, excludedFolders: exclusions,
                                              promptAvoidanceFolders: promptAvoidanceFolders, developerArtifactsOnly: true)
        try Task.checkCancellation()
        if scan.nodes.isEmpty {
            throw NSError(domain: "DeveloperCleanup", code: 2, userInfo: [NSLocalizedDescriptionKey:
                scan.incompleteEvidence?.first?.reason ?? "This folder could not be scanned."])
        }
        let exclusionPolicy = FolderExclusions(paths: exclusions)
        let candidates = scan.nodes.filter { $0.parent != nil && $0.isDirectory && !$0.isSymlink
            && CleanupGuidance.focusedDeveloperNames.contains($0.name) }
        let eligible = Dictionary(uniqueKeysWithValues: candidates.compactMap { node -> (Int, URL)? in
            let url = scan.url(for: node.id)
            return CleanupGuidance.isRegenerableFolder(path: url.path, home: home) ? (node.id, url) : nil
        })
        let roots = candidates.filter { node in
            guard eligible[node.id] != nil else { return false }
            return !ancestors(of: node.id, in: scan).contains { eligible[$0] != nil }
        }
        let rootIDs = Set(roots.map(\.id))
        let repositories = Set(scan.nodes.lazy.filter { $0.name == ".git" }
            .flatMap { ancestors(of: $0.id, in: scan).filter(rootIDs.contains) })
        let openFiles = try captureOpenFiles(roots.compactMap { eligible[$0.id]?.path })

        var items: [Item] = []
        for node in roots {
            try Task.checkCancellation()
            guard let url = eligible[node.id] else { continue }
            let reason: String?
            do {
                try ToolStorage.validateCleanup(path: url.path)
                if exclusionPolicy.blocksCleanup(url) { throw CleanupPreflightError.excludedFolder(url.path) }
                try CleanupSafety.validate(url: url, expected: node, root: URL(fileURLWithPath: scan.rootPath),
                                           allowingRegenerableChanges: true, home: home)
                if node.isScanIncomplete == true { reason = "Some contents could not be checked. This folder is kept." }
                else if repositories.contains(node.id), node.name == "node_modules" {
                    reason = "Contains a Git checkout. This folder is kept."
                } else if !FileManager.default.isDeletableFile(atPath: url.path) {
                    reason = "macOS does not allow removal with the current permissions."
                } else if let user = openFiles?.user(of: url.path) { reason = "In use by \(user). Quit it and scan again." }
                else { reason = nil }
            } catch { reason = error.localizedDescription }
            items.append(Item(id: node.id, path: url.path, allocatedBytes: node.allocatedBytes,
                              canDeletePermanently: CleanupGuidance.canDeletePermanently(path: url.path, home: home),
                              keptReason: reason))
        }
        return Self(items: items.sorted {
            if ($0.keptReason == nil) != ($1.keptReason == nil) { return $0.keptReason == nil }
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path < $1.path
        }, scan: scan, exclusions: exclusions, home: home)
    }

    public func clean(ids: Set<Int>, permanently: Bool,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Outcome {
        let selected = items.filter { ids.contains($0.id) && $0.keptReason == nil }
        var outcome = Outcome()
        guard selected.count == ids.count else { return outcome }
        let dependencies = selected.filter { CleanupGuidance.isProjectDependencies(path: $0.path) }.map(\.path)
        var openFiles: CleanupActiveUse.OpenFiles?
        let root = URL(fileURLWithPath: scan.rootPath)
        let policy = FolderExclusions(paths: exclusions)
        for (index, item) in selected.enumerated() {
            do {
                try Task.checkCancellation()
                progress?(index + 1, selected.count)
                let url = URL(fileURLWithPath: item.path)
                let isDependencies = CleanupGuidance.isProjectDependencies(path: item.path)
                if isDependencies, openFiles?.isFresh != true {
                    openFiles = try Self.captureOpenFiles(dependencies)
                }
                try await CleanupPreflight.validate(ids: [item.id], in: scan, excludedFolders: exclusions,
                    regenerableIDs: [item.id], home: home, openFiles: isDependencies ? openFiles : nil)
                try Task.checkCancellation()
                if policy.blocksCleanup(url) { throw CleanupPreflightError.excludedFolder(url.path) }
                try CleanupSafety.validate(url: url, expected: scan.nodes[item.id], root: root,
                                           allowingRegenerableChanges: true, home: home)
                if permanently && item.canDeletePermanently {
                    guard CleanupGuidance.canDeletePermanently(path: url.path, home: home),
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
