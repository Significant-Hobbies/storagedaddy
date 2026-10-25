import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct CleanupBatchTests {
    private func fixture(_ names: [String]) async throws -> (URL, ScanResult, [String: Int]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try Data(repeating: name == "independent.bin" ? 2 : 1, count: 4096).write(to: root.appendingPathComponent(name))
        }
        let scan = try await DiskScanner.scan(root: root)
        let ids = Dictionary(uniqueKeysWithValues: scan.nodes.dropFirst().map { ($0.name, $0.id) })
        return (root, scan, ids)
    }

    private func wait(_ model: ExplorerModel) async throws {
        // A batch can run a fresh, bounded process probe for each item.
        for _ in 0..<6_000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Cleanup did not finish")
    }

    @Test func permanentCleanupOnlyDeletesDependenciesAndPreservesEarlierFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-permanent-\(UUID())")
        for path in ["project/package.json", "project/node_modules/index.js", "checkpoint.pt", "earlier-problem"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let scan = try await DiskScanner.scan(root: root)
        let dependencies = try #require(scan.nodes.first { $0.name == "node_modules" }?.id)
        let checkpoint = try #require(scan.nodes.first { $0.name == "checkpoint.pt" }?.id)
        let earlier = try #require(scan.nodes.first { $0.name == "earlier-problem" }?.id)
        let model = ExplorerModel(); model.scan = scan; model.staged = [dependencies, checkpoint]
        model.quickCleanupFailures[earlier] = "Kept from staging"
        #expect(model.permanentCleanupIDs == [dependencies])
        model.deleteNodeCachesPermanently = false
        #expect(model.permanentCleanupIDs.isEmpty)
        // Even a caller trying to bypass the review cannot permanently delete originals.
        model.performReviewedCleanup([checkpoint, dependencies], permanentlyDeleting: [checkpoint, dependencies], moveToTrash: { _ in
            Issue.record("Permanent cleanup must not use Trash")
            return nil
        })
        try await wait(model)
        #expect(!FileManager.default.fileExists(atPath: scan.url(for: dependencies).path))
        #expect(FileManager.default.fileExists(atPath: scan.url(for: checkpoint).path))
        #expect(model.quickCleanupFailures[checkpoint] != nil)
        #expect(model.quickCleanupFailures[earlier] == "Kept from staging")
        #expect(model.lastPermanentlyDeletedCount == 1)
        #expect(model.lastTrashedURLs.isEmpty)
        #expect(model.progress.contains("1 permanently deleted · 0 moved to Trash · 1 skipped"))
    }

    @Test func permanentFailureKeepsFolderAndContinuesToTrashItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-permanent-denied-\(UUID())")
        let dependencies = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("package.json"))
        try Data([1]).write(to: dependencies.appendingPathComponent("index.js"))
        try Data([2]).write(to: root.appendingPathComponent("other"))
        let scan = try await DiskScanner.scan(root: root)
        let dep = try #require(scan.nodes.first { $0.name == "node_modules" }?.id)
        let other = try #require(scan.nodes.first { $0.name == "other" }?.id)
        let model = ExplorerModel(); model.scan = scan; model.staged = [dep, other]
        let recovery = root.appendingPathComponent("recoverable-other")
        model.performReviewedCleanup([dep, other], permanentlyDeleting: [dep], deletePermanently: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: recovery)
            return recovery
        })
        try await wait(model)
        #expect(FileManager.default.fileExists(atPath: dependencies.path))
        #expect(model.quickCleanupFailures[dep] != nil)
        #expect(model.lastPermanentlyDeletedCount == 0)
        #expect(model.lastTrashedURLs == [recovery])
        #expect(model.staged.isEmpty)
    }

    @Test func missingChangedAndDeniedItemsDoNotBlockLaterItems() async throws {
        let (root, scan, ids) = try await fixture(["missing", "changed", "denied", "good"])
        let requested = try ["missing", "changed", "denied", "good"].map { try #require(ids[$0]) }
        try FileManager.default.moveItem(at: root.appendingPathComponent("missing"), to: root.appendingPathComponent("already-removed"))
        try Data([2, 3]).write(to: root.appendingPathComponent("changed"))
        let model = ExplorerModel(); model.scan = scan; model.staged = Set(requested)
        model.quickCleanupCandidateIDs = requested
        var attempts: [String] = []
        let recovery = root.appendingPathComponent("recoverable-good")
        model.performReviewedCleanup(requested, moveToTrash: { url in
            attempts.append(url.lastPathComponent)
            if url.lastPathComponent == "denied" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: recovery)
            return recovery
        })
        try await wait(model)
        #expect(attempts == ["denied", "good"])
        #expect(model.quickCleanupFailures.count == 3)
        #expect(model.staged.isEmpty)
        #expect(model.easyCleanupIDs.isEmpty)
        #expect(model.lastTrashedURLs == [recovery])
        #expect(model.message == nil)
        #expect(model.progress.contains("1 moved to Trash · 3 skipped"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("changed").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied").path))
        #expect(FileManager.default.fileExists(atPath: recovery.path))
    }

    @Test func cancellationPreservesCompletedMovesAndLeavesRemainingItemsStaged() async throws {
        let (root, scan, ids) = try await fixture(["first", "second"])
        let first = try #require(ids["first"]), second = try #require(ids["second"])
        let model = ExplorerModel(); model.scan = scan; model.staged = [first, second]
        let recovery = root.appendingPathComponent("recoverable-first")
        model.performReviewedCleanup([first, second], moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: recovery)
            model.cancel()
            return recovery
        })
        try await wait(model)
        #expect(model.staged == [second])
        #expect(model.lastTrashedURLs == [recovery])
        #expect(model.quickCleanupFailures.isEmpty)
        #expect(model.progress.contains("Cleanup cancelled · 1 moved to Trash"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("second").path))
    }

    @Test func missingKeptDuplicateBlocksOnlyItsOwnCopies() async throws {
        let (root, scan, ids) = try await fixture(["keep.bin", "copy.bin", "independent.bin"])
        let keep = try #require(ids["keep.bin"]), copy = try #require(ids["copy.bin"])
        let independent = try #require(ids["independent.bin"])
        let model = ExplorerModel(); model.scan = scan
        model.findDuplicates()
        for _ in 0..<200 {
            if !model.duplicatesLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.stageDuplicateCopies([copy])
        // Fresh process evidence can take several seconds on a busy Mac.
        for _ in 0..<2_000 {
            if model.staged == [copy], !model.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.staged == [copy])
        try FileManager.default.moveItem(at: scan.url(for: keep), to: root.appendingPathComponent("held-keep.bin"))
        model.staged.insert(independent)
        let recovery = root.appendingPathComponent("recoverable-independent.bin")
        model.performReviewedCleanup([copy, independent], moveToTrash: { url in
            #expect(url == scan.url(for: independent), "A duplicate without its reviewed survivor must stay")
            try FileManager.default.moveItem(at: url, to: recovery)
            return recovery
        })
        try await wait(model)
        #expect(model.quickCleanupFailures[copy] != nil)
        #expect(FileManager.default.fileExists(atPath: scan.url(for: copy).path))
        #expect(model.lastTrashedURLs == [recovery])
    }
}
