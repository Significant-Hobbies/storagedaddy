import Darwin
import DiskCore
import Foundation

struct DeveloperCleanupReview: Sendable {
    struct Item: Identifiable, Sendable {
        struct ID: Hashable, Sendable {
            let scope: Int
            let node: Int
        }

        let id: ID
        fileprivate let artifact: DeveloperCleanupPlan.Item
        var path: String { artifact.path }
        var allocatedBytes: Int64 { artifact.allocatedBytes }
        var keptReason: String? { artifact.keptReason }
        var canDeletePermanently: Bool { artifact.canDeletePermanently }
    }

    struct Scope: Identifiable, Sendable {
        fileprivate let url: URL
        fileprivate let plan: DeveloperCleanupPlan?
        let error: String?
        var path: String { url.standardizedFileURL.path }
        var id: String { path }
    }

    struct Outcome: Sendable {
        var deleted: Set<Item.ID> = []
        var trashed: Set<Item.ID> = []
        var kept: [Item.ID: String] = [:]
        var cancelled = false
    }

    let id = UUID()
    let scopes: [Scope]
    let items: [Item]
    var skipped: Int { scopes.reduce(0) { $0 + ($1.plan?.skipped ?? 0) } }

    private struct FolderIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// Each plan owns its original scan and validates only items from that scan.
    /// Treat overlapping inputs as an invalid scope so no artifact is selected twice.
    static func prepare(roots: [URL], excludedFolders: [String], promptAvoidance: [String]) async throws -> Self {
        let canonical = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let identities = canonical.map(FolderIdentity.init)
        for (index, root) in canonical.enumerated() {
            let otherPaths = canonical.indices.filter { $0 != index }
            let ancestors = FolderExclusions(paths: otherPaths.map { canonical[$0].path }, resolveAliases: false)
            let otherIdentities = Set(otherPaths.compactMap { identities[$0] })
            var ancestor = root
            var aliasesOtherScope = false
            while !otherIdentities.isEmpty, !ancestor.path.isEmpty {
                if let identity = FolderIdentity(ancestor), otherIdentities.contains(identity) {
                    aliasesOtherScope = true
                    break
                }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
            if ancestors.contains(root.path) || aliasesOtherScope {
                throw NSError(domain: "DeveloperCleanupReview", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Choose separate folders. One of your selections already contains another."])
            }
        }
        var scopes: [Scope] = []
        for root in roots {
            try Task.checkCancellation()
            let path = root.standardizedFileURL.path
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let avoidance = promptAvoidance.filter { path != $0 && !path.hasPrefix($0 + "/") }
            do {
                let plan = try await DeveloperCleanupPlan.prepare(root: root, excluding: excludedFolders,
                                                                   promptAvoidanceFolders: avoidance)
                scopes.append(Scope(url: root, plan: plan, error: nil))
            } catch is CancellationError { throw CancellationError() }
            catch { scopes.append(Scope(url: root, plan: nil, error: error.localizedDescription)) }
        }
        let items = scopes.enumerated().flatMap { scope, entry in
            (entry.plan?.items ?? []).map { Item(id: .init(scope: scope, node: $0.id), artifact: $0) }
        }.sorted {
            if ($0.keptReason == nil) != ($1.keptReason == nil) { return $0.keptReason == nil }
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.path < $1.path
        }
        return Self(scopes: scopes, items: items)
    }

    func clean(ids: Set<Item.ID>, permanently: Bool, progress: @escaping @Sendable (Int, Int) -> Void) async -> Outcome {
        let eligible = Set(items.filter { $0.keptReason == nil }.map(\.id))
        var outcome = Outcome()
        guard ids.isSubset(of: eligible) else { return outcome }
        let selection = Dictionary(grouping: ids, by: \.scope)
        var processed = 0
        for (index, scope) in scopes.enumerated() {
            if Task.isCancelled { outcome.cancelled = true; break }
            guard let plan = scope.plan, let batch = selection[index] else { continue }
            let access = scope.url.startAccessingSecurityScopedResource()
            defer { if access { scope.url.stopAccessingSecurityScopedResource() } }
            let offset = processed
            let result = await plan.clean(ids: Set(batch.map(\.node)), permanently: permanently) {
                item, _ in progress(offset + item, ids.count)
            }
            outcome.deleted.formUnion(result.deleted.map { Item.ID(scope: index, node: $0) })
            outcome.trashed.formUnion(result.trashed.map { Item.ID(scope: index, node: $0) })
            for (node, reason) in result.kept { outcome.kept[Item.ID(scope: index, node: node)] = reason }
            if result.cancelled { outcome.cancelled = true; break }
            processed += batch.count
        }
        return outcome
    }
}
