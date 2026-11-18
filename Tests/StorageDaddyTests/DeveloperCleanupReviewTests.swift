import Foundation
import Testing
@testable import StorageDaddy

struct DeveloperCleanupReviewTests {
    @Test func combinesIndependentScopesAndReportsAnUnavailableFolder() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("developer-review-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let projects = root.appendingPathComponent("Projects")
        let worktrees = root.appendingPathComponent("Worktrees")
        let missing = root.appendingPathComponent("Unavailable")
        for scope in [projects, worktrees] {
            let folder = scope.appendingPathComponent("node_modules")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: scope.appendingPathComponent("package.json"))
            try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("index.js"))
        }
        let review = try await DeveloperCleanupReview.prepare(roots: [projects, worktrees, missing],
                                                               excludedFolders: [], promptAvoidance: [])
        #expect(review.scopes.count == 3)
        #expect(review.scopes.last?.error != nil)
        #expect(review.items.count == 2)
        #expect(Set(review.items.map(\.id.node)).count == 1)
        #expect(Set(review.items.map(\.id)).count == 2)

        let selected = try #require(review.items.first { $0.id.scope == 1 })
        let result = await review.clean(ids: [selected.id], permanently: true) { _, _ in }
        #expect(result.deleted == [selected.id])
        #expect(fm.fileExists(atPath: projects.appendingPathComponent("node_modules/index.js").path))
        #expect(!fm.fileExists(atPath: worktrees.appendingPathComponent("node_modules").path))
        #expect(fm.fileExists(atPath: worktrees.appendingPathComponent("package.json").path))
    }

    @Test func rejectsNestedScopesBeforeScanning() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("developer-overlap-\(UUID())")
        do {
            _ = try await DeveloperCleanupReview.prepare(roots: [root, root.appendingPathComponent("Worktrees")],
                                                          excludedFolders: [], promptAvoidance: [])
            Issue.record("A folder and its descendant would double-count the scan")
        } catch {
            #expect(error.localizedDescription.contains("overlaps"))
            #expect(error.localizedDescription.contains("Worktrees"))
        }
    }

    @Test func rejectsTwoNamesForTheSameFolder() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("developer-alias-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        let original = base.appendingPathComponent("Projects")
        let alias = base.appendingPathComponent("projects")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: alias.path) else { return }
        await #expect(throws: NSError.self) {
            try await DeveloperCleanupReview.prepare(roots: [original, alias], excludedFolders: [], promptAvoidance: [])
        }
    }
}
