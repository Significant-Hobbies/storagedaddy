import Darwin
import XCTest
@testable import DiskCore

final class ScanTreeArchiveTests: XCTestCase {
    func testFullTreeReopensIdentitiesNestedFoldersAndSharingWithoutDrive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("source"), history = directory.appendingPathComponent("history")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("project/node_modules"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("project/node_modules/module.js")
        try Data(repeating: 1, count: 4096).write(to: file)
        XCTAssertEqual(link(file.path, source.appendingPathComponent("project/linked.js").path), 0)
        let scan = try await DiskScanner.scan(root: source)
        let saved = try SnapshotHistoryStore.save(scan: scan, directory: history, includeFileIndex: true)
        // Prove that reopening uses saved metadata, including attribution,
        // after the entire fixture source directory is no longer present.
        try FileManager.default.removeItem(at: source)
        let restored = try ScanTreeArchive.read(snapshot: saved, directory: history)
        XCTAssertEqual(restored.nodes.map(\.name), scan.nodes.map(\.name))
        XCTAssertEqual(restored.nodes.map(\.children), scan.nodes.map(\.children))
        XCTAssertEqual(restored.nodes.map(\.inode), scan.nodes.map(\.inode))
        XCTAssertEqual(restored.nodes.map(\.allocatedBytes), scan.nodes.map(\.allocatedBytes))
        XCTAssertEqual(restored.fileAllocationDetails, scan.fileAllocationDetails)
        XCTAssertEqual(DeveloperInsights.analyze(restored).first { $0.category == .nodeModules }?.fileCount, 1)
    }

    func testOversizeSnapshotDoesNotLeaveIndexOrTreeBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var root = DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)
        var nodes = [root]
        for id in 1...30_000 { nodes.append(DiskNode(id: id, parent: 0, name: "\(id)-" + String(repeating: "x", count: 180), isDirectory: false)) }
        root.children = Array(1...30_000); nodes[0] = root
        let scan = ScanResult(rootPath: "/fixture", nodes: nodes)
        XCTAssertThrowsError(try SnapshotHistoryStore.save(scan: scan, directory: directory, includeFileIndex: true))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCompleteLineTruncationCannotReopenOrProduceFalseDiffs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source"), history = directory.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1]).write(to: source.appendingPathComponent("file"))
        let scan = try await DiskScanner.scan(root: source)
        let saved = try SnapshotHistoryStore.save(scan: scan, directory: history, includeFileIndex: true)
        let tree = ScanTreeArchive.url(id: saved.id, directory: history)
        let lines = try Data(contentsOf: tree).split(separator: 10)
        var prefix = Data()
        for line in lines.prefix(2) { prefix.append(contentsOf: line); prefix.append(10) }
        try prefix.write(to: tree)
        XCTAssertThrowsError(try ScanTreeArchive.read(snapshot: saved, directory: history))
        let index = ScanFileIndex.url(id: saved.id, directory: history)
        let indexHeader = try Data(contentsOf: index).split(separator: 10)[0]
        var headerOnly = Data(indexHeader); headerOnly.append(10)
        try headerOnly.write(to: index)
        XCTAssertThrowsError(try ScanFileIndex.compare(before: saved, after: saved, directory: history))
    }

    func testOversizeFullMetadataRetainsSummaryAndFileIndexWithWarning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var scan = ScanResult(rootPath: "/fixture", nodes: [DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)])
        scan.errors = [String(repeating: "x", count: 1_048_576)]
        let saved = try SnapshotHistoryStore.save(scan: scan, directory: directory, includeFileIndex: true)
        XCTAssertEqual(saved.fileIndexVersion, 1)
        XCTAssertNil(saved.fullTreeVersion)
        XCTAssertNotNil(saved.archivalWarning)
        let loaded = try XCTUnwrap(SnapshotHistoryStore.load(directory: directory).snapshots.first)
        XCTAssertEqual(loaded.archivalWarning, saved.archivalWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ScanTreeArchive.url(id: saved.id, directory: directory).path))
        XCTAssertEqual(try ScanFileIndex.compare(before: loaded, after: loaded, directory: directory).changeCount, 0)
    }

    func testIndexQuotaFailureDoesNotLeakPublishedTree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scan = ScanResult(rootPath: "/fixture", nodes: [DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)])
        let id = UUID()
        XCTAssertThrowsError(try ScanTreeArchive.write(scan: scan, id: id, directory: directory, byteBudget: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ScanTreeArchive.url(id: id, directory: directory).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
