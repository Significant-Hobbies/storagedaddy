import Darwin
import XCTest
@testable import DiskCore

final class ScanFileIndexTests: XCTestCase {
    func testNestedChangesRoundTripAndNetTotalsSurvivePathFilter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: history) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("nested/removed"))
        try Data(repeating: 2, count: 100).write(to: root.appendingPathComponent("nested/changed"))
        let a = try await DiskScanner.scan(root: root)
        let savedA = try SnapshotHistoryStore.save(scan: a, directory: history, includeFileIndex: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("nested/removed"))
        try Data(repeating: 3, count: 150).write(to: root.appendingPathComponent("nested/changed"))
        try Data(repeating: 4, count: 200).write(to: root.appendingPathComponent("nested/added"))
        let b = try await DiskScanner.scan(root: root)
        let savedB = try SnapshotHistoryStore.save(scan: b, directory: history, includeFileIndex: true)
        let all = try ScanFileIndex.compare(before: savedA, after: savedB, directory: history)
        XCTAssertEqual(all.changeCount, 3)
        XCTAssertEqual(all.logicalDelta, 150)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: all.changes.map { ($0.path, $0.kind.rawValue) }),
                       ["nested/added": "added", "nested/removed": "removed", "nested/changed": "modified"])
        let filtered = try ScanFileIndex.compare(before: savedA, after: savedB, directory: history, search: "removed", limit: 1)
        XCTAssertEqual(filtered.changes.map(\.path), ["nested/removed"])
        XCTAssertEqual(filtered.logicalDelta, 150)
        let listing = try SnapshotHistoryStore.load(directory: history)
        XCTAssertEqual(listing.snapshots.count, 2)
        XCTAssertEqual(listing.unreadableCount, 0)
        XCTAssertEqual(listing.snapshots.first?.fileIndexVersion, 1)
    }

    func testLegacyDifferentRootAndSymlinkIndexFailClearly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scan = ScanResult(rootPath: "/fixture", nodes: [DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)])
        let a = SavedScanSnapshot(id: UUID(), savedAt: Date(), scan: scan)
        let b = SavedScanSnapshot(id: UUID(), savedAt: Date(), scan: scan)
        XCTAssertThrowsError(try ScanFileIndex.compare(before: a, after: b, directory: directory))
        let outside = directory.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        XCTAssertEqual(symlink(outside.path, ScanFileIndex.url(id: a.id, directory: directory).path), 0)
        XCTAssertThrowsError(try ScanFileIndex.compare(before: a, after: b, directory: directory))
    }

    func testPartialCoverageAndTruncationAreVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var root = DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true, children: [1, 2])
        root.isScanIncomplete = true
        let a = ScanResult(rootPath: "/fixture", nodes: [root, DiskNode(id: 1, parent: 0, name: "a", isDirectory: false, logicalBytes: 1), DiskNode(id: 2, parent: 0, name: "b", isDirectory: false, logicalBytes: 2)], skipped: 1)
        let b = ScanResult(rootPath: "/fixture", nodes: [DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)])
        let first = try SnapshotHistoryStore.save(scan: a, directory: directory, includeFileIndex: true)
        let second = try SnapshotHistoryStore.save(scan: b, directory: directory, includeFileIndex: true)
        let diff = try ScanFileIndex.compare(before: first, after: second, directory: directory, limit: 1)
        XCTAssertTrue(diff.partialCoverage)
        XCTAssertTrue(diff.truncated)
        XCTAssertEqual(diff.changeCount, 2)
        XCTAssertEqual(diff.logicalDelta, -3)
    }
}
