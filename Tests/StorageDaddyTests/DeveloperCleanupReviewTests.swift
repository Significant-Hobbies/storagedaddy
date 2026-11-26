import Darwin
import Foundation
import Testing
@testable import StorageDaddy

struct DeveloperCleanupReviewTests {
    @MainActor @Test func largePersonalFilesCanBeReviewedAndTrashedWithoutCapacityOrADeveloperPlan() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let projects = home.appendingPathComponent("Projects")
        let nested = projects.appendingPathComponent("Samples")
        let skip = projects.appendingPathComponent("Private")
        let modules = projects.appendingPathComponent("node_modules")
        let temporaryTrash = home.appendingPathComponent("Trash")
        for dir in [nested, skip, modules, temporaryTrash] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: home) }
        let recording = nested.appendingPathComponent("recording.mov")
        let archive = projects.appendingPathComponent("installer.zip")
        let bytes = Data(repeating: 42, count: 65536)
        try bytes.write(to: recording)
        for url in [archive, skip.appendingPathComponent("keep"), modules.appendingPathComponent("library"),
                    projects.appendingPathComponent("credentials.json")] {
            try Data(repeating: 1, count: 8192).write(to: url)
        }
        try fm.createSymbolicLink(at: projects.appendingPathComponent("alias.mov"), withDestinationURL: recording)
        let rows = LargeStorageEntry.ordinaryFiles(in: [projects, nested], exclusions: [skip.path],
                                                  volume: home, minimumBytes: 4096).entries
        #expect(rows.map(\.title) == ["recording.mov", "installer.zip"])
        let first = try #require(rows.first)
        let second = try #require(rows.last)
        let model = ExplorerModel(developerCleanupPreferences: nil)
        model.openSpaceTarget(nil, home: home)
        await model.waitForCurrentStorageOperation()
        #expect(model.isFindingStorageCulprits)
        #expect(model.developerCleanupSelectedIDs.isEmpty)
        // The same path now names a different file.
        try fm.moveItem(at: archive, to: home.appendingPathComponent("original.zip"))
        try bytes.write(to: archive)
        var moved = false
        await #expect(throws: (any Error).self) {
            try await model.trashLargeFile(second) { _ in moved = true; return nil }
        }
        #expect(!moved)
        #expect(try Data(contentsOf: archive) == bytes)
        let recovered = temporaryTrash.appendingPathComponent(recording.lastPathComponent)
        try await model.trashLargeFile(first) { url in
            try fm.moveItem(at: url, to: recovered)
            return recovered
        }
        #expect(!fm.fileExists(atPath: recording.path))
        #expect(try Data(contentsOf: recovered) == bytes)
        #expect(model.lastTrashedURLs.contains(recovered))
        #expect(fm.fileExists(atPath: skip.appendingPathComponent("keep").path))
    }

    @Test func automaticCleanupWithholdsSharedPnpmAndProtectsGuestsWhileExplicitPruneUsesReviewedStore() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        let store = home.appendingPathComponent("Library/pnpm/store/v11/v10")
        let blobs = store.appendingPathComponent("files/ab")
        let cache = home.appendingPathComponent(".lume/cache")
        let registry = cache.appendingPathComponent("ghcr")
        let guest = home.appendingPathComponent(".lume/installed/disk.img")
        for dir in [bin, blobs, registry, guest.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let image = registry.appendingPathComponent("fixture-image")
        let free = blobs.appendingPathComponent(String(repeating: "a", count: 126))
        let linked = blobs.appendingPathComponent(String(repeating: "b", count: 126))
        let installed = home.appendingPathComponent("installed.js")
        for file in [image, guest, free, linked] { try Data(repeating: 7, count: 65_536).write(to: file) }
        try fm.linkItem(at: linked, to: installed)
        let pnpm = """
        #!/bin/sh
        if [ "$1 $2" = 'store path' ]; then echo "$PWD/Library/pnpm/store/v11/v10"; exit; fi
        test "$1" = --store-dir && test "$2" -ef "$PWD/Library/pnpm/store/v11/v10" || exit 2
        case "$3" in --config.cache-dir=*) ;; *) exit 3 ;; esac
        test "$4 $5" = 'store prune' || exit 4
        /bin/rm "$PWD/Library/pnpm/store/v11/v10/files/ab/\(free.lastPathComponent)"
        """
        let lume = """
        #!/bin/sh
        if [ "$1 $2" = 'config get' ]; then
          printf '%s\\n' 'Cache directory: ~/.lume/cache' 'Configured VM storage locations:' '  - home: ~/.lume (default)'
          exit
        fi
        test "$1" = prune || exit 5
        /bin/rm "$PWD/.lume/installed/disk.img" 2>/dev/null && exit 6
        /bin/rm "$PWD/.lume/cache/ghcr/fixture-image"
        """
        for (name, script) in [("pnpm", pnpm), ("lume", lume)] {
            let file = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let blocked = try SpaceTargetCache.discoverManagedStores(home: home, exclusions: [image.path, free.path])
        #expect(blocked.isEmpty)
        let caches = try SpaceTargetCache.discoverManagedStores(home: home, exclusions: [])
        #expect(caches.count == 2)
        let pnpmRow = try #require(caches.first { $0.tool == .pnpm })
        var metadata = stat()
        #expect(lstat(free.path, &metadata) == 0)
        #expect(pnpmRow.bytes == Int64(metadata.st_blocks) * 512)
        let review = DeveloperCleanupReview(scopes: [], items: []).reclaimable(on: pnpmRow.device, caches: caches)
        let ids = Set(review.items.map(\.id))
        #expect(ids.count == 1)
        #expect(review.withheld.contains { $0.item.path == store.path })
        let outcome = await review.clean(ids: ids, permanently: true) { _, _ in }
        #expect(outcome.deleted == ids, "Kept reasons: \(outcome.kept)")
        #expect(fm.fileExists(atPath: free.path))
        let explicit = try pnpmRow.tool.pruneReviewedStore(executable: pnpmRow.executable, directory: store, home: home)
        #expect(explicit.status == 0)
        #expect(!fm.fileExists(atPath: free.path))
        #expect(!fm.fileExists(atPath: image.path))
        #expect(fm.fileExists(atPath: installed.path))
        #expect(fm.fileExists(atPath: linked.path))
        #expect(fm.fileExists(atPath: guest.path))
    }

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

    @MainActor @Test func goBuildCleanupPinsTheReviewedCache() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        let directory = home.appendingPathComponent("Library/Caches/go-build")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("object")
        try Data(repeating: 1, count: 8192).write(to: entry)
        let go = bin.appendingPathComponent("go")
        let script = """
        #!/bin/sh
        case "$1 $2" in
          'env GOCACHE') echo "$PWD/Library/Caches/go-build" ;;
          'clean -cache') test "$GOCACHE" -ef "$PWD/Library/Caches/go-build" && touch "$PWD/confirmed" ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: go)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: go.path)
        #expect(try SpaceTargetCache.discover(home: home, exclusions: [entry.path]).isEmpty)
        let cache = try #require(SpaceTargetCache.discover(home: home, exclusions: []).first)
        #expect(cache.tool == .go)
        try fm.createDirectory(at: home.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let model = ExplorerModel(developerCleanupPreferences: nil, quickProjectPlanner: { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return DeveloperCleanupReview(scopes: [], items: [])
        })
        let capacity = try #require(StartupCapacity(total: 100, available: 50))
        model.openSpaceTarget(capacity, home: home)
        let scan = Task { await model.waitForCurrentStorageOperation() }
        for _ in 0..<200 where !model.searchingForMoreCleanup { try await Task.sleep(for: .milliseconds(25)) }
        let initial = try #require(model.developerCleanupPlan)
        #expect(model.searchingForMoreCleanup && model.canEditCleanupReview)
        let selected = model.developerCleanupSelectedIDs
        #expect(selected.count == 1)
        model.confirmDeveloperCleanup(planID: initial.id, ids: selected, permanently: true)
        await model.waitForCurrentStorageOperation()
        await scan.value
        #expect(model.developerCleanupPlan?.id == initial.id)
        #expect(model.developerCleanupOutcome?.deleted == selected)
        #expect(!model.searchingForMoreCleanup && !model.busy)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("confirmed").path))
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
