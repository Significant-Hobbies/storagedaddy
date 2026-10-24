import Darwin
import XCTest
@testable import DiskCore

final class SnapshotHistoryStoreTests: XCTestCase {
    func testRetentionGroupsByRootAndKeepsNewestRecords() {
        let records = (0..<20).map { index in
            SavedScanSnapshot(id: UUID(), savedAt: Date(timeIntervalSince1970: Double(index)), scan: makeScan(root: index < 10 ? "/one" : "/two", allocated: 1))
        }
        XCTAssertEqual(SnapshotHistoryStore.excessSnapshots(records, retainingPerRoot: 7).map(\.savedAt.timeIntervalSince1970), [0, 1, 2, 10, 11, 12])
        XCTAssertTrue(SnapshotHistoryStore.excessSnapshots(records, retainingPerRoot: 0).isEmpty)
    }

    func testPartialTrashFailureRetainsVisibleRecordForRetry() throws {
        let directory = try fixture()
        let saved = try SnapshotHistoryStore.save(scan: makeScan(root: "/one", allocated: 1), directory: directory, includeFileIndex: true)
        var attempted: [String] = []
        XCTAssertThrowsError(try SnapshotHistoryStore.trash(id: saved.id, directory: directory) { url in
            attempted.append(url.pathExtension)
            if url.pathExtension == "tree" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        XCTAssertEqual(attempted, ["index", "tree"])
        XCTAssertEqual(try SnapshotHistoryStore.load(directory: directory).snapshots.count, 1)
        try SnapshotHistoryStore.trash(id: saved.id, directory: directory) { try FileManager.default.removeItem(at: $0) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRoundTripPersistsCompactTopLevelTotals() throws {
        let directory = try fixture().appendingPathComponent("history")
        let scan = makeScan(root: "/first", allocated: 12_288)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let saved = try SnapshotHistoryStore.save(scan: scan, directory: directory, savedAt: date)
        let listing = try SnapshotHistoryStore.load(directory: directory)

        XCTAssertEqual(listing.snapshots.count, 1)
        XCTAssertEqual(listing.snapshots[0].id, saved.id)
        XCTAssertEqual(listing.snapshots[0].savedAt, date)
        XCTAssertEqual(listing.snapshots[0].scan.rootPath, "/first")
        XCTAssertEqual(listing.snapshots[0].scan.nodes.count, 2)
        XCTAssertEqual(listing.snapshots[0].scan.nodes[1].allocatedBytes, 12_288)
        XCTAssertEqual(listing.unreadableCount, 0)
        XCTAssertFalse(listing.limitReached)
        let directoryMode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        let stored = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let fileMode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testSnapshotsForDifferentRootsCoexistNewestFirst() throws {
        let directory = try fixture()
        _ = try SnapshotHistoryStore.save(scan: makeScan(root: "/one", allocated: 1), directory: directory, savedAt: Date(timeIntervalSince1970: 1))
        _ = try SnapshotHistoryStore.save(scan: makeScan(root: "/two", allocated: 2), directory: directory, savedAt: Date(timeIntervalSince1970: 2))

        let listing = try SnapshotHistoryStore.load(directory: directory)

        XCTAssertEqual(listing.snapshots.map(\.scan.rootPath), ["/two", "/one"])
    }

    func testBrokenAndSymlinkEntriesAreSkippedAndReported() throws {
        let directory = try fixture()
        _ = try SnapshotHistoryStore.save(scan: makeScan(root: "/good", allocated: 1), directory: directory)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertEqual(symlink(outside.path, directory.appendingPathComponent("00000000000000000001-\(UUID().uuidString).json").path), 0)

        let listing = try SnapshotHistoryStore.load(directory: directory)

        XCTAssertEqual(listing.snapshots.map(\.scan.rootPath), ["/good"])
        XCTAssertEqual(listing.unreadableCount, 2)
    }

    func testMissingDirectoryIsEmptyAndEntryLimitIsReported() throws {
        let parent = try fixture()
        let missing = parent.appendingPathComponent("missing")
        let empty = try SnapshotHistoryStore.load(directory: missing)
        XCTAssertTrue(empty.snapshots.isEmpty)
        XCTAssertFalse(empty.limitReached)

        for index in 0..<512 {
            let id = UUID()
            let value = SavedScanSnapshot(id: id, savedAt: Date(timeIntervalSince1970: Double(index)), scan: SnapshotArchive.compact(makeScan(root: "/older/\(index)", allocated: 1)))
            let name = String(format: "%020lld-%@.json", Int64(index) * 1_000_000, id.uuidString)
            try JSONEncoder().encode(value).write(to: parent.appendingPathComponent(name))
        }
        _ = try SnapshotHistoryStore.save(scan: makeScan(root: "/newest", allocated: 1), directory: parent)
        let limited = try SnapshotHistoryStore.load(directory: parent)
        XCTAssertTrue(limited.limitReached)
        XCTAssertEqual(limited.snapshots.count, 512)
        XCTAssertEqual(limited.snapshots.first?.scan.rootPath, "/newest")
        XCTAssertFalse(limited.snapshots.contains { $0.scan.rootPath == "/older/0" })
        XCTAssertEqual(limited.unreadableCount, 0)
    }

    func testOversizedEntryIsRejectedWithoutHidingGoodSnapshot() throws {
        let directory = try fixture()
        _ = try SnapshotHistoryStore.save(scan: makeScan(root: "/good", allocated: 1), directory: directory)
        let oversized = directory.appendingPathComponent("00000000000000000001-\(UUID().uuidString).json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 8 * 1024 * 1024 + 1)
        try handle.close()

        let listing = try SnapshotHistoryStore.load(directory: directory)

        XCTAssertEqual(listing.snapshots.map(\.scan.rootPath), ["/good"])
        XCTAssertEqual(listing.unreadableCount, 1)
    }

    func testNamedPipeIsRejectedWithoutBlockingHistory() throws {
        let directory = try fixture()
        let pipe = directory.appendingPathComponent("00000000000000000001-\(UUID().uuidString).json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let listing = try SnapshotHistoryStore.load(directory: directory)
        XCTAssertTrue(listing.snapshots.isEmpty)
        XCTAssertEqual(listing.unreadableCount, 1)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeScan(root: String, allocated: Int64) -> ScanResult {
        let nodes = [
            DiskNode(id: 0, parent: nil, name: "root", isDirectory: true, logicalBytes: allocated, allocatedBytes: allocated, children: [1]),
            DiskNode(id: 1, parent: 0, name: "folder", isDirectory: true, logicalBytes: allocated, allocatedBytes: allocated, children: [2]),
            DiskNode(id: 2, parent: 1, name: "file", isDirectory: false, logicalBytes: allocated, allocatedBytes: allocated),
        ]
        return ScanResult(rootPath: root, nodes: nodes)
    }
}
