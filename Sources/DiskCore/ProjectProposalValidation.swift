import Foundation

/// Refresh the full workspace metadata and Git index after final confirmation.
/// Artifact identity checks remain the existing cleanup preflight's responsibility.
public enum ProjectProposalValidation {
    public static func validate(scan: ScanResult, artifactOwners: [Int: Int], recoveryPlans: [Int: String],
        excludedFolders: [String],
        scanWorkspace: @escaping @Sendable (URL, [String]) async throws -> ScanResult = { root, excluded in
            try await DiskScanner.scan(root: root, excludedFolders: excluded)
        }, runGit: @escaping @Sendable (URL, [String]) -> String? = GitCheckoutProbe.runLocal) async throws {
        for owner in Set(artifactOwners.values) {
            try Task.checkCancellation()
            guard scan.nodes.indices.contains(owner) else { throw changed() }
            let root = scan.url(for: owner)
            let fresh = try await scanWorkspace(root, excludedFolders)
            let worker = Task.detached(priority: .utility) {
                let check = { try Task.checkCancellation() }
                let groups = try DeveloperInsights.analyze(fresh, cancellationCheck: check)
                let report = try DeveloperReport.build(scan: fresh, groups: groups, cancellationCheck: check)
                let preliminary = try ProjectPurgeReview.build(scan: fresh, report: report, cancellationCheck: check)
                guard let workspace = preliminary.first(where: { $0.id == 0 }) else { throw changed() }
                var requested = Set<Int>(), plans: [Int: String] = [:]
                for (oldID, projectID) in artifactOwners where projectID == owner {
                    guard scan.nodes.indices.contains(oldID), let plan = recoveryPlans[oldID], !plan.isEmpty else { throw changed() }
                    let path = scan.url(for: oldID).path
                    guard path.hasPrefix(root.path + "/") else { throw changed() }
                    let relative = String(path.dropFirst(root.path.count + 1))
                    var id = 0
                    for component in relative.split(separator: "/") {
                        try Task.checkCancellation()
                        guard let next = fresh.nodes[id].children.first(where: {
                            fresh.nodes.indices.contains($0) && fresh.nodes[$0].name == component
                        }) else { throw changed() }
                        id = next
                    }
                    guard workspace.artifacts.contains(where: { $0.id == id }) else { throw changed() }
                    requested.insert(id); plans[id] = plan
                }
                let git = try ProjectGitTrackingProbe.collect(scan: fresh, projectID: 0, artifactIDs: workspace.artifacts.map(\.id), run: runGit)
                let records = try ProjectPurgeReview.build(scan: fresh, report: report,
                    probes: [0: ProjectPurgeProbe(git: git, recoveryPlans: plans)], cancellationCheck: check)
                guard Set(ProjectPurgeReview.stageableSelection(requested, in: records)) == requested else { throw changed() }
            }
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }
    private static func changed() -> NSError {
        NSError(domain: "ProjectReview", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Project evidence changed or could not be verified. Refresh Projects and review the artifacts again."])
    }
}
