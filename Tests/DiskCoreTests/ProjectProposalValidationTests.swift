import Foundation
import Testing
@testable import DiskCore

struct ProjectProposalValidationTests {
    private func fixture(recent: Bool = false) -> ScanResult {
        let old = Date().addingTimeInterval(-30 * 86400)
        return ScanResult(rootPath: "/tmp/project-proposal-fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "Project", isDirectory: true, modified: old, children: [1, 2, 4]),
            DiskNode(id: 1, parent: 0, name: "package.json", isDirectory: false, modified: recent ? Date() : old),
            DiskNode(id: 2, parent: 0, name: "node_modules", isDirectory: true, modified: old, children: [3]),
            DiskNode(id: 3, parent: 2, name: "index.js", isDirectory: false, modified: old),
            DiskNode(id: 4, parent: 0, name: ".git", isDirectory: true, modified: old)
        ])
    }
    @Test func finalReviewAcceptsOnlyFreshProtectedEvidenceAndPlan() async throws {
        let original = fixture(), fresh = fixture()
        try await ProjectProposalValidation.validate(scan: original, artifactOwners: [2: 0], recoveryPlans: [2: "Reviewed restore from lockfile"],
            excludedFolders: [], scanWorkspace: { _, _ in fresh }, runGit: { _, args in args.first == "rev-parse" ? "true\n" : "" })
        let recent = fixture(recent: true)
        await #expect(throws: NSError.self) {
            try await ProjectProposalValidation.validate(scan: original, artifactOwners: [2: 0], recoveryPlans: [2: "Reviewed restore from lockfile"],
                excludedFolders: [], scanWorkspace: { _, _ in recent }, runGit: { _, args in args.first == "rev-parse" ? "true\n" : "" })
        }
        await #expect(throws: NSError.self) {
            try await ProjectProposalValidation.validate(scan: original, artifactOwners: [2: 0], recoveryPlans: [2: "Reviewed restore from lockfile"],
                excludedFolders: [], scanWorkspace: { _, _ in fresh }, runGit: { _, args in args.first == "rev-parse" ? "true\n" : "node_modules/index.js\0" })
        }
        await #expect(throws: NSError.self) {
            try await ProjectProposalValidation.validate(scan: original, artifactOwners: [2: 0], recoveryPlans: [:],
                excludedFolders: [], scanWorkspace: { _, _ in fresh }, runGit: { _, args in args.first == "rev-parse" ? "true\n" : "" })
        }
    }
}
