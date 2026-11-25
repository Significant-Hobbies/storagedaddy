import Foundation
import Testing
@testable import StorageDaddy

struct DeveloperCleanupReviewTests {
    @MainActor @Test func deselectionsAndNewFoldersStayUncheckedAcrossReviews() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("developer-selection-\(UUID())")
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let added = root.appendingPathComponent("Added")
        let defaults = UserDefaults.standard
        let priorFolders = defaults.object(forKey: "developerCleanupFolders")
        defer {
            defaults.set(priorFolders, forKey: "developerCleanupFolders")
            try? fm.removeItem(at: root)
        }

        func makeDependencies(in folder: URL) throws -> URL {
            let dependencies = folder.appendingPathComponent("node_modules")
            try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("package.json"))
            try Data("fixture".utf8).write(to: dependencies.appendingPathComponent("entry.js"))
            return dependencies
        }

        let unchecked = try makeDependencies(in: first)
        let checked = try makeDependencies(in: second)
        let new = try makeDependencies(in: added)
        let model = ExplorerModel()

        func completedReview() async throws -> DeveloperCleanupReview {
            let deadline = Date().addingTimeInterval(15)
            while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(!model.busy)
            return try #require(model.developerCleanupPlan)
        }

        func item(_ path: URL, in plan: DeveloperCleanupReview) throws -> DeveloperCleanupReview.Item {
            try #require(plan.items.first { $0.path == path.resolvingSymlinksInPath().path })
        }

        model.findDeveloperCleanup(in: [first, second])
        let initial = try await completedReview()
        let original = try item(checked, in: initial)
        #expect(model.developerCleanupSelectedIDs == Set(initial.items.map(\.id)))
        model.setDeveloperCleanupSelection([original.id], planID: initial.id)

        model.findDeveloperCleanup(in: [added, first, second], retainingReviewOnFailure: true)
        let expanded = try await completedReview()
        let retained = try item(checked, in: expanded)
        #expect(retained.id != original.id)
        #expect(model.developerCleanupSelectedIDs == [retained.id])
        model.setDeveloperCleanupSelection(Set(expanded.items.map(\.id)), planID: initial.id)
        #expect(model.developerCleanupSelectedIDs == [retained.id])

        model.openQuickCleanup()
        model.openDeveloperCleanup()
        let revisited = try await completedReview()
        #expect(revisited.id != expanded.id)
        let revisitedSelection = try item(checked, in: revisited)
        #expect(model.developerCleanupSelectedIDs == [revisitedSelection.id])

        let originalDirectory = second.appendingPathComponent(".original-dependencies")
        try fm.moveItem(at: checked, to: originalDirectory)
        _ = try makeDependencies(in: second)
        model.rescanDeveloperCleanup()
        let rescanned = try await completedReview()
        #expect(rescanned.id != revisited.id)
        #expect(model.developerCleanupSelectedIDs.isEmpty)
        model.confirmDeveloperCleanup(planID: rescanned.id, ids: [try item(checked, in: rescanned).id], permanently: true)
        #expect(!model.busy)
        #expect(model.developerCleanupOutcome == nil)
        for folder in [unchecked, checked, new, originalDirectory] {
            #expect(fm.fileExists(atPath: folder.appendingPathComponent("entry.js").path))
        }
    }

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
