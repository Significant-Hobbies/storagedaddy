import Foundation
import Testing
@testable import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct QuickCleanupTests {
    private func fixture(_ paths: [String]) async throws -> (URL, ScanResult, ExplorerModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-direct-\(UUID())")
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("temporary fixture".utf8).write(to: url)
        }
        let scan = try await DiskScanner.scan(root: root)
        let model = ExplorerModel(); model.scan = scan
        return (root, scan, model)
    }

    private func id(_ path: String, in scan: ScanResult) throws -> Int {
        try #require(scan.nodes.first { scan.url(for: $0.id).path == URL(fileURLWithPath: scan.rootPath).appendingPathComponent(path).path }?.id)
    }

    private func wait(_ model: ExplorerModel) async throws {
        for _ in 0..<6_000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Direct cleanup did not finish")
    }

    @Test func nativeDeleteRemovesOnlyDependenciesAndPreservesReviewAndOriginals() async throws {
        let (root, scan, model) = try await fixture(["project/package.json", "project/node_modules/index.js",
            "project/source.swift", ".codex/history.jsonl", ".lume/vm/disk.img", "tools/__pycache__/module.pyc", "staged/keep.txt"])
        let dependencies = try id("project/node_modules", in: scan)
        let history = try id(".codex", in: scan), vm = try id(".lume", in: scan)
        let pycache = try id("tools/__pycache__", in: scan), staged = try id("staged", in: scan)
        model.quickCleanupCandidateIDs = [dependencies, history, vm, pycache]
        model.staged = [staged]
        model.deleteNodeCachesPermanently = false
        let incomplete = model.incompleteCleanup
        let selection = try #require(model.quickPermanentCleanup())
        #expect(selection.ids == [dependencies])
        model.deleteQuickCleanup(selection)
        try await wait(model)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("project/node_modules").path))
        for path in ["project/package.json", "project/source.swift", ".codex/history.jsonl", ".lume/vm/disk.img", "tools/__pycache__/module.pyc", "staged/keep.txt"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
        #expect(model.staged == [staged])
        #expect(model.incompleteCleanup == incomplete)
        #expect(model.lastPermanentlyDeletedCount == 1)
        #expect(model.lastTrashedURLs.isEmpty)
        #expect(model.quickCleanupFailures.isEmpty)
        #expect(model.progress.hasPrefix("Cleanup complete · 1 permanently deleted"))
    }

    @Test func stagedAncestorsAndDescendantsStayUntouched() async throws {
        let (root, scan, model) = try await fixture(["a/package.json", "a/node_modules/index.js", "b/package.json", "b/node_modules/index.js"])
        let a = try id("a/node_modules", in: scan), b = try id("b/node_modules", in: scan)
        let staged: Set<Int> = try [id("a", in: scan), id("b/node_modules/index.js", in: scan)]
        model.staged = staged; model.quickCleanupCandidateIDs = [a, b]
        #expect(model.quickPermanentCleanup() == nil)
        #expect(model.staged == staged)
        for path in ["a/node_modules/index.js", "b/node_modules/index.js"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }

    @Test func displayedSelectionCannotExpandWhenNewCandidatesArrive() async throws {
        let (root, scan, model) = try await fixture(["a/package.json", "a/node_modules/index.js", "b/package.json", "b/node_modules/index.js"])
        let a = try id("a/node_modules", in: scan), b = try id("b/node_modules", in: scan)
        model.quickCleanupCandidateIDs = [a]
        let selection = try #require(model.quickPermanentCleanup())
        model.quickCleanupCandidateIDs = [a, b]
        model.deleteQuickCleanup(selection)
        try await wait(model)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a/node_modules").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b/node_modules/index.js").path))
        #expect(model.quickCleanupCandidateIDs == [b])
    }

    @Test func replacingEvenTheSameScanInvalidatesDisplayedAuthorization() async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/index.js"])
        let dependencies = try id("node_modules", in: scan)
        model.quickCleanupCandidateIDs = [dependencies]
        let selection = try #require(model.quickPermanentCleanup())
        model.scan = scan; model.quickCleanupCandidateIDs = [dependencies]
        model.deleteQuickCleanup(selection)
        #expect(!model.busy)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/index.js").path))
    }

    @Test func injectedHomeIsRespectedThroughCacheRemoval() async throws {
        let (root, scan, model) = try await fixture([".npm/_cacache/content/data", ".npm/settings", ".cache/uv/data", "source.swift"])
        let cache = try id(".npm/_cacache", in: scan), uv = try id(".cache/uv", in: scan)
        model.quickCleanupCandidateIDs = [cache, uv]
        let selection = try #require(model.quickPermanentCleanup(home: root.path))
        #expect(selection.ids == [cache])
        model.deleteQuickCleanup(selection)
        try await wait(model)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".npm/_cacache").path))
        for path in [".npm/settings", ".cache/uv/data", "source.swift"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }

    @Test func incompleteCacheIsKeptWithoutOfferingAnOverride() async throws {
        let (root, scan, model) = try await fixture([".npm/_cacache/content/data", ".npm/_cacache/.env"])
        let cache = try id(".npm/_cacache", in: scan)
        model.quickCleanupCandidateIDs = [cache]
        let selection = try #require(model.quickPermanentCleanup(home: root.path))
        model.deleteQuickCleanup(selection)
        try await wait(model)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".npm/_cacache/.env").path))
        #expect(model.lastPermanentlyDeletedCount == 0)
        #expect(model.quickCleanupFailures[cache] != nil)
        #expect(model.incompleteCleanup.isEmpty)
        #expect(model.staged.isEmpty)
    }

    enum Change: CaseIterable { case inode, symlink, cancellation, scan, staging }

    @Test(arguments: Change.allCases)
    func changesDuringAsyncValidationKeepTheCandidate(_ change: Change) async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/index.js", "sentinel/keep.txt"])
        let dependencies = try id("node_modules", in: scan), sentinel = try id("sentinel", in: scan)
        model.staged = [sentinel]; model.quickCleanupCandidateIDs = [dependencies]
        let selection = try #require(model.quickPermanentCleanup())
        model.deleteQuickCleanup(selection)
        for _ in 0..<1_000 {
            if model.progress.hasPrefix("Cleaning 1 of 1") { break }
            await Task.yield()
        }
        try #require(model.busy, "Mutation must arrive while validation is suspended")
        let candidate = root.appendingPathComponent("node_modules")
        switch change {
        case .inode:
            try FileManager.default.moveItem(at: candidate, to: root.appendingPathComponent("original-dependencies"))
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: candidate.appendingPathComponent("index.js"))
        case .symlink:
            try FileManager.default.moveItem(at: candidate, to: root.appendingPathComponent("original-dependencies"))
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: root.appendingPathComponent("sentinel"))
        case .cancellation: model.cancel()
        case .scan: model.scan = scan
        case .staging: model.staged.insert(dependencies)
        }
        try await wait(model)
        #expect(FileManager.default.fileExists(atPath: candidate.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sentinel/keep.txt").path))
        #expect(model.lastPermanentlyDeletedCount == 0)
        #expect(model.staged == (change == .staging ? [sentinel, dependencies] : [sentinel]))
        #expect(model.incompleteCleanup.isEmpty)
    }

    @Test func excludedFolderIsKeptAndExclusionChangesAreBlockedWhileBusy() async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/index.js", "staged/keep.txt"])
        let dependencies = try id("node_modules", in: scan), staged = try id("staged", in: scan)
        let candidate = root.appendingPathComponent("node_modules")
        model.addExcludedFolders([candidate])
        defer { model.removeExcludedFolder(candidate.path) }
        model.staged = [staged]; model.quickCleanupCandidateIDs = [dependencies]
        let selection = try #require(model.quickPermanentCleanup())
        model.deleteQuickCleanup(selection)
        let previous = model.excludedFolders
        model.addExcludedFolders([root.appendingPathComponent("staged")])
        #expect(model.excludedFolders == previous)
        try await wait(model)
        #expect(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.js").path))
        #expect(model.lastPermanentlyDeletedCount == 0)
        #expect(model.quickCleanupFailures[dependencies] != nil)
        #expect(model.staged == [staged])
    }

    @Test func perFolderFailureContinuesWithoutConsumingStagedWork() async throws {
        let (root, scan, model) = try await fixture(["a/package.json", "a/node_modules/index.js", "b/package.json", "b/node_modules/index.js", "staged/keep.txt"])
        let a = try id("a/node_modules", in: scan), b = try id("b/node_modules", in: scan), staged = try id("staged", in: scan)
        model.staged = [staged]; model.quickCleanupCandidateIDs = [a, b]
        let selection = try #require(model.quickPermanentCleanup())
        let deniedPath = root.appendingPathComponent("a/node_modules").path
        model.deleteQuickCleanup(selection, deletePermanently: { url in
            if url.path == deniedPath {
                try FileManager.default.removeItem(at: url.appendingPathComponent("index.js"))
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        })
        try await wait(model)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/node_modules").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a/node_modules/index.js").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b/node_modules").path))
        #expect(model.quickCleanupFailures[a]?.contains("Some contents may already have been removed") == true)
        #expect(model.lastPermanentlyDeletedCount == 1)
        #expect(model.staged == [staged])
    }

    @Test func nativeStagedActionExecutesDisplayedMixedDestinations() async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/index.js", "ordinary.txt", "source.swift"])
        let dependencies = try id("node_modules", in: scan), ordinary = try id("ordinary.txt", in: scan)
        model.staged = [dependencies, ordinary]
        let selection = try #require(model.nativeCleanupSelection())
        #expect(selection.permanentIDs == [dependencies])
        let recovery = root.appendingPathComponent("recoverable-ordinary.txt")
        model.performNativeCleanup(selection, moveToTrash: { url in
            #expect(url == scan.url(for: ordinary))
            try FileManager.default.moveItem(at: url, to: recovery)
            return recovery
        })
        try await wait(model)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ordinary.txt").path))
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        for path in ["package.json", "source.swift"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
        #expect(model.staged.isEmpty)
        #expect(model.lastPermanentlyDeletedCount == 1)
        #expect(model.lastTrashedURLs == [recovery])
    }

    enum NativeChange: CaseIterable { case selection, scan, destination }

    @Test(arguments: NativeChange.allCases)
    func nativeStagedActionRejectsChangedAuthorization(_ change: NativeChange) async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/index.js", "other.txt"])
        let dependencies = try id("node_modules", in: scan), other = try id("other.txt", in: scan)
        model.staged = [dependencies]
        let selection = try #require(model.nativeCleanupSelection())
        switch change {
        case .selection: model.staged.insert(other)
        case .scan: model.scan = scan
        case .destination: model.deleteNodeCachesPermanently = false
        }
        let staged = model.staged
        model.performNativeCleanup(selection, deletePermanently: { _ in Issue.record("Stale native authorization must not delete") },
                                   moveToTrash: { _ in Issue.record("Stale native authorization must not move"); return nil })
        #expect(!model.busy)
        #expect(model.staged == staged)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/index.js").path))
    }

    @Test func savedScanRequiresFreshScanBeforeEitherNativeCleanupAction() async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/index.js"])
        let dependencies = try id("node_modules", in: scan)
        let directory = root.deletingLastPathComponent().appendingPathComponent("storage-saved-direct-\(UUID())")
        let snapshot = try SnapshotHistoryStore.save(scan: scan, directory: directory, includeFileIndex: true)
        model.openSavedScan(snapshot, directory: directory)
        try await wait(model)
        #expect(model.scanIsHistorical)
        #expect(model.quickPermanentCleanup() == nil)
        model.staged = [dependencies]
        #expect(model.nativeCleanupSelection() == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/index.js").path))
        model.scan = scan
        model.quickCleanupCandidateIDs = [dependencies]
        model.staged = []
        #expect(!model.scanIsHistorical)
        #expect(model.quickPermanentCleanup() != nil)
    }

    @Test func completedRemovalIsRecordedBeforeChangedStagingStopsLaterItems() async throws {
        let (root, scan, model) = try await fixture(["a/package.json", "a/node_modules/index.js", "b/package.json", "b/node_modules/index.js", "staged/keep.txt"])
        let a = try id("a/node_modules", in: scan), b = try id("b/node_modules", in: scan), staged = try id("staged", in: scan)
        model.quickCleanupCandidateIDs = [a, b]
        let selection = try #require(model.quickPermanentCleanup())
        model.deleteQuickCleanup(selection, deletePermanently: { url in
            try FileManager.default.removeItem(at: url)
            DispatchQueue.main.sync { MainActor.assumeIsolated { model.staged.insert(staged) } }
        })
        try await wait(model)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a/node_modules").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b/node_modules/index.js").path))
        #expect(model.lastPermanentlyDeletedCount == 1)
        #expect(model.quickCleanupCandidateIDs == [b])
        #expect(model.staged == [staged])
        #expect(model.progress.contains("1 not processed"))
    }

    @Test func keptDuplicateInsideDependencyFolderPreventsDirectDeletion() async throws {
        let (root, scan, model) = try await fixture(["package.json", "node_modules/keep.bin", "copy.bin"])
        let kept = try id("node_modules/keep.bin", in: scan), copy = try id("copy.bin", in: scan)
        let dependencies = try id("node_modules", in: scan)
        model.duplicateGroups = [.init(id: "temporary-duplicates", nodeIDs: [kept, copy], wastedBytes: 4096)]
        model.stageDuplicateCopies([copy])
        for _ in 0..<6_000 {
            if model.staged == [copy], !model.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.staged == [copy])
        model.quickCleanupCandidateIDs = [dependencies]
        let selection = try #require(model.quickPermanentCleanup())
        model.deleteQuickCleanup(selection)
        try await wait(model)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/keep.bin").path))
        #expect(model.quickCleanupFailures[dependencies] != nil)
        #expect(model.lastPermanentlyDeletedCount == 0)
        #expect(model.staged == [copy])
    }
}
