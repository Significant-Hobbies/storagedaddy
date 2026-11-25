import Darwin
import Foundation
import Testing
@testable import StorageDaddy

struct DeveloperCleanupReviewTests {
    @Test func targetCacheRechecksExclusionsAndFolderIdentityAndUsesReviewedCommand() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("target-cache-\(UUID())").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        let directory = home.appendingPathComponent(".cache/uv")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 65536).write(to: directory.appendingPathComponent("entry"))
        let script = bin.appendingPathComponent("uv")
        let commands = """
        #!/bin/sh
        case "$1 $2" in
          'cache dir') echo "$PWD/.cache/uv" ;;
          'cache clean') test "$3" = --cache-dir && test "$4" -ef "$PWD/.cache/uv" && touch "$PWD/confirmed" ;;
          *) exit 1 ;;
        esac
        """
        try Data(commands.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(try SpaceTargetCache.discover(home: home, exclusions: [directory.appendingPathComponent("entry").path]).isEmpty)
        let caches = try SpaceTargetCache.discover(home: home, exclusions: [])
        let cache = try #require(caches.first)
        let review = DeveloperCleanupReview(scopes: [], items: []).reclaimable(on: cache.device, caches: caches)
        let selected = Set(review.items.map(\.id))
        #expect(selected.count == 1)
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("confirmed").path))
        let lockFile = directory.appendingPathComponent(".lock")
        let holder = open(lockFile.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        try #require(holder >= 0)
        defer { close(holder) }
        try #require(flock(holder, LOCK_SH | LOCK_NB) == 0)
        let busyReview = DeveloperCleanupReview(scopes: [], items: []).reclaimable(on: cache.device, caches: caches)
        #expect(busyReview.items.isEmpty)
        #expect(busyReview.withheld.first?.item.allocatedBytes == cache.bytes)
        #expect(busyReview.withheld.first?.reason.contains("active uv task") == true)
        let becameBusy = await review.clean(ids: selected, permanently: true) { _, _ in }
        #expect(becameBusy.deleted.isEmpty)
        #expect(becameBusy.kept.values.first?.contains("active uv task") == true)
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("confirmed").path))
        try #require(flock(holder, LOCK_UN) == 0)
        let originalLock = directory.appendingPathComponent("original-lock")
        try fm.moveItem(at: lockFile, to: originalLock)
        try fm.createSymbolicLink(at: lockFile, withDestinationURL: originalLock)
        let unverifiable = DeveloperCleanupReview(scopes: [], items: []).reclaimable(on: cache.device, caches: caches)
        #expect(unverifiable.items.isEmpty)
        #expect(unverifiable.withheld.first?.reason.contains("Could not verify") == true)
        let unverified = await review.clean(ids: selected, permanently: true) { _, _ in }
        #expect(unverified.kept.values.first?.contains("Could not verify") == true)
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("confirmed").path))
        try fm.removeItem(at: lockFile)
        try fm.moveItem(at: originalLock, to: lockFile)
        let confirmed = await review.clean(ids: selected, permanently: true) { _, _ in }
        #expect(confirmed.kept.isEmpty)
        #expect(confirmed.deleted == selected)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("confirmed").path))
        try fm.moveItem(at: directory, to: home.appendingPathComponent("old-cache"))
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let replaced = await review.clean(ids: selected, permanently: true) { _, _ in }
        #expect(Set(replaced.kept.keys) == selected)
        #expect(replaced.deleted.isEmpty)
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func deselectionsAndNewFoldersStayUncheckedAcrossReviews() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("developer-selection-\(UUID())")
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let added = root.appendingPathComponent("Added")
        defer { try? fm.removeItem(at: root) }

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
        let model = ExplorerModel(developerCleanupPreferences: nil) { roots, _ in
            let scopes = roots.map { DeveloperCleanupReview.Scope(url: $0) }
            let items = try roots.enumerated().map { index, root in
                let path = root.appendingPathComponent("node_modules").resolvingSymlinksInPath().path
                var entry = stat()
                guard lstat(path, &entry) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
                return DeveloperCleanupReview.Item(id: .init(scope: index, node: 1), path: path, allocatedBytes: 4_096,
                    keptReason: nil, canDeletePermanently: true, device: UInt64(UInt32(bitPattern: entry.st_dev)), inode: UInt64(entry.st_ino))
            }
            return DeveloperCleanupReview(scopes: scopes, items: items)
        }

        func completedReview() async throws -> DeveloperCleanupReview {
            await model.waitForCurrentStorageOperation()
            try Task.checkCancellation()
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
        #expect(model.developerCleanupDeletesPermanently)
        model.setDeveloperCleanupSelection([original.id], planID: initial.id)
        model.setDeveloperCleanupDeletesPermanently(false, planID: initial.id)

        model.findDeveloperCleanup(in: [added, first, second], retainingReviewOnFailure: true)
        let expanded = try await completedReview()
        let retained = try item(checked, in: expanded)
        #expect(retained.id != original.id)
        #expect(model.developerCleanupSelectedIDs == [retained.id])
        model.setDeveloperCleanupSelection(Set(expanded.items.map(\.id)), planID: initial.id)
        model.setDeveloperCleanupDeletesPermanently(true, planID: initial.id)
        #expect(model.developerCleanupSelectedIDs == [retained.id])
        #expect(!model.developerCleanupDeletesPermanently)

        model.openQuickCleanup()
        model.openDeveloperCleanup()
        let revisited = try await completedReview()
        #expect(revisited.id != expanded.id)
        let revisitedSelection = try item(checked, in: revisited)
        #expect(model.developerCleanupSelectedIDs == [revisitedSelection.id])
        #expect(!model.developerCleanupDeletesPermanently)
        model.confirmDeveloperCleanup(planID: revisited.id, ids: [revisitedSelection.id], permanently: true)
        #expect(!model.busy)
        #expect(fm.fileExists(atPath: checked.path))

        let originalDirectory = second.appendingPathComponent(".original-dependencies")
        try fm.moveItem(at: checked, to: originalDirectory)
        _ = try makeDependencies(in: second)
        model.rescanDeveloperCleanup()
        let rescanned = try await completedReview()
        #expect(rescanned.id != revisited.id)
        #expect(model.developerCleanupSelectedIDs.isEmpty)
        #expect(!model.developerCleanupDeletesPermanently)
        model.confirmDeveloperCleanup(planID: rescanned.id, ids: [try item(checked, in: rescanned).id], permanently: false)
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
