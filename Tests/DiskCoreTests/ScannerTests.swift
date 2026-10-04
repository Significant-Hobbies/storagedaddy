import Darwin
@testable import DiskCore
import Foundation
import XCTest

final class ScannerTests: XCTestCase {
    func testUnreadableDirectoryIsNotReportedAsAnEmptyDirectory() async throws {
        try XCTSkipIf(geteuid() == 0, "Root can bypass directory permissions")
        let fixture = try makeFixture()
        let blocked = fixture.appendingPathComponent("blocked")
        let empty = fixture.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        try write([1, 2, 3], to: blocked.appendingPathComponent("not-empty.bin"))
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { _ = chmod(blocked.path, 0o700) }
        for backend in [ScanBackend.foundation, .bulk, .parallel] {
            let scan = try await DiskScanner.scan(root: fixture, backend: backend)
            XCTAssertEqual(try node(named: "blocked", in: scan).isContentsUnreadable, true)
            XCTAssertEqual(try node(named: "empty", in: scan).isContentsUnreadable, false)
            XCTAssertEqual(scan.nodes[0].isScanIncomplete, true)
            XCTAssertEqual(try node(named: "empty", in: scan).isScanIncomplete, false)
            XCTAssertEqual(try node(named: "blocked", in: scan).allocatedBytes, 0)
            XCTAssertFalse(scan.nodes.contains { $0.name == "not-empty.bin" })
            XCTAssertTrue(scan.incompleteEvidence?.contains { $0.path == blocked.path && $0.reason == "unreadable directory" } == true)
        }
    }

    func testLegacyNodesDecodeWithoutUnreadableFlag() throws {
        let node = DiskNode(id: 0, parent: nil, name: "legacy", isDirectory: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        object.removeValue(forKey: "isContentsUnreadable")
        object.removeValue(forKey: "isScanIncomplete")
        let decoded = try JSONDecoder().decode(DiskNode.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.isContentsUnreadable)
        XCTAssertNil(decoded.isScanIncomplete)
    }

    func testPromptAvoidanceSkipsProtectedDirectoryAndReportsIncompleteScan() async throws {
        let fixture = try makeFixture()
        let downloads = fixture.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        try write([1], to: downloads.appendingPathComponent("private.bin"))
        try write([2], to: fixture.appendingPathComponent("visible.bin"))

        let result = try await DiskScanner.scan(root: fixture, backend: .foundation,
            promptAvoidanceFolders: [downloads.path])
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.nodes[0].isScanIncomplete, true)
        XCTAssertEqual(result.incompleteEvidence?.first?.reason, "skipped to avoid a macOS permission prompt")
        XCTAssertFalse(result.nodes.contains { $0.name == "Downloads" || $0.name == "private.bin" })
        XCTAssertTrue(result.nodes.contains { $0.name == "visible.bin" })

        let protectedRoot = try await DiskScanner.scan(root: downloads,
            promptAvoidanceFolders: [downloads.path])
        XCTAssertTrue(protectedRoot.nodes.isEmpty)
        XCTAssertEqual(protectedRoot.skipped, 1)
    }

    func testFoundationScanAggregatesSparseFilesAndDeduplicatesHardLinks() async throws {
        let fixture = try makeFixture()
        let ordinary = fixture.appendingPathComponent("ordinary.bin")
        let sparse = fixture.appendingPathComponent("nested/sparse.bin")
        let linked = fixture.appendingPathComponent("nested/ordinary-link.bin")

        try write([0xA5], to: ordinary)
        try writeSparseFile(at: sparse, size: 16 * 1024 * 1024)
        XCTAssertEqual(link(ordinary.path, linked.path), 0)

        let result = try await DiskScanner.scan(root: fixture, backend: .foundation)
        let ordinaryNode = try node(named: "ordinary.bin", in: result)
        let linkNode = try node(named: "ordinary-link.bin", in: result)
        let sparseNode = try node(named: "sparse.bin", in: result)
        let nested = try node(named: "nested", in: result)

        XCTAssertEqual(ordinaryNode.logicalBytes, 1)
        XCTAssertEqual(linkNode.logicalBytes, 1, "logical size counts each directory entry")
        XCTAssertEqual(ordinaryNode.inode, linkNode.inode)
        XCTAssertEqual(sparseNode.logicalBytes, 16 * 1024 * 1024)
        try XCTSkipIf(
            sparseNode.allocatedBytes >= sparseNode.logicalBytes,
            "the temporary test volume does not expose sparse allocation"
        )
        XCTAssertLessThan(sparseNode.allocatedBytes, sparseNode.logicalBytes)
        XCTAssertEqual(nested.logicalBytes, sparseNode.logicalBytes + linkNode.logicalBytes)
        XCTAssertEqual(result.nodes[0].logicalBytes, 16 * 1024 * 1024 + 2)
        let hardLinkAllocation = ordinaryNode.allocatedBytes + linkNode.allocatedBytes
        XCTAssertTrue(
            ordinaryNode.allocatedBytes == 0 || linkNode.allocatedBytes == 0,
            "exactly one directory entry owns the physical allocation"
        )
        XCTAssertEqual(result.nodes[0].allocatedBytes, hardLinkAllocation + sparseNode.allocatedBytes)
    }

    func testBulkAndFoundationProduceEquivalentMetadataAndSkipSensitivePaths() async throws {
        let fixture = try makeFixture()
        try write([1, 2, 3], to: fixture.appendingPathComponent("visible.txt"))
        try write([4], to: fixture.appendingPathComponent(".env.local"))
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent(".ssh"), withIntermediateDirectories: false)
        try write([5], to: fixture.appendingPathComponent(".ssh/id_rsa"))
        try write([6], to: fixture.appendingPathComponent("credentials.json"))
        XCTAssertEqual(symlink("visible.txt", fixture.appendingPathComponent("visible-link").path), 0)

        let foundation = try await DiskScanner.scan(root: fixture, backend: .foundation)
        DiskScannerDiagnostics.shared.reset()
        let bulk = try await DiskScanner.scan(root: fixture, backend: .bulk)
        let counters = DiskScannerDiagnostics.shared.snapshot()

        XCTAssertEqual(signature(of: bulk), signature(of: foundation))
        XCTAssertEqual(bulk.errors, [])
        XCTAssertGreaterThan(counters.bulkDirectories, 0, "bulk scans must execute getattrlistbulk")
        XCTAssertEqual(counters.bulkFallbacks, 0, "a malformed bulk parser must not be disguised by Foundation")
        XCTAssertEqual(counters.foundationDirectories, 0)
        XCTAssertEqual(foundation.skipped, 3)
        XCTAssertEqual(foundation.incompleteEvidence?.map(\.reason), [
            "excluded by sensitive path policy",
            "excluded by sensitive path policy",
            "excluded by sensitive path policy"
        ])
        XCTAssertTrue(foundation.incompleteEvidence?.allSatisfy { $0.path.hasPrefix(fixture.path + "/") } == true)
        XCTAssertFalse(foundation.nodes.contains { [".env.local", ".ssh", "credentials.json"].contains($0.name) })
        let symlinkNode = try node(named: "visible-link", in: foundation)
        XCTAssertTrue(symlinkNode.isSymlink)
        XCTAssertEqual(symlinkNode.logicalBytes, 0)
        XCTAssertEqual(symlinkNode.allocatedBytes, 0)

        let protectedRoot = try await DiskScanner.scan(root: fixture.appendingPathComponent(".ssh"))
        XCTAssertEqual(protectedRoot.skipped, 1)
        XCTAssertTrue(protectedRoot.nodes.isEmpty)

        let protectedAlias = fixture.appendingPathComponent("ssh-alias")
        XCTAssertEqual(symlink(".ssh", protectedAlias.path), 0)
        let protectedThroughSymlink = try await DiskScanner.scan(root: protectedAlias)
        XCTAssertEqual(protectedThroughSymlink.skipped, 1)
        XCTAssertTrue(protectedThroughSymlink.nodes.isEmpty)
    }

    func testProgressStartsAtRootAndCancellationIsObserved() async throws {
        let fixture = try makeFixture()
        try write([7], to: fixture.appendingPathComponent("one"))
        let progress = ProgressSink()
        _ = try await DiskScanner.scan(root: fixture, backend: .foundation) { update in
            progress.append(update)
        }
        XCTAssertEqual(progress.values.first?.entries, 1)
        XCTAssertEqual(progress.values.first?.path, fixture.path)

        let task = Task {
            try await DiskScanner.scan(root: fixture, backend: .foundation)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the scanner checks cancellation before it reads the root.
        }
    }

    func testLiveTotalsMatchCompletedScanWithoutDoubleCountingLinks() async throws {
        let fixture = try makeFixture()
        try write([1, 2, 3], to: fixture.appendingPathComponent("nested/data"))
        XCTAssertEqual(link(fixture.appendingPathComponent("nested/data").path, fixture.appendingPathComponent("alias").path), 0)
        XCTAssertEqual(symlink("nested", fixture.appendingPathComponent("shortcut").path), 0)
        try write([9], to: fixture.appendingPathComponent(".env.test"))
        let sink = ProgressSink()
        let result = try await DiskScanner.scan(root: fixture) { sink.append($0) }
        let final = try XCTUnwrap(sink.values.last)
        XCTAssertEqual(final.entries, result.nodes.count)
        XCTAssertEqual(final.allocatedBytes, result.nodes[0].allocatedBytes)
        XCTAssertEqual(final.logicalBytes, result.nodes[0].logicalBytes)
        XCTAssertEqual(final.files, 2)
        XCTAssertEqual(final.skipped, 1)
        XCTAssertEqual(final.locations.reduce(Int64(0)) { $0 + $1.allocatedBytes }, final.allocatedBytes)
        XCTAssertLessThanOrEqual(final.locations.count, 8)
        XCTAssertFalse(final.locations.contains { $0.name == ".env.test" })
        for (earlier, later) in zip(sink.values, sink.values.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.allocatedBytes, later.allocatedBytes)
            XCTAssertLessThanOrEqual(earlier.entries, later.entries)
        }
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskbuddy-scanner-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url, options: .atomic)
    }

    private func writeSparseFile(at url: URL, size: Int64) throws {
        try Data(repeating: 1, count: Int(size)).write(to: url)
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw POSIXError.fromErrno() }
        defer { close(descriptor) }
        var hole = fpunchhole_t()
        hole.fp_offset = 4 * 1024
        hole.fp_length = size - 8 * 1024
        guard fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 else {
            throw XCTSkip("the temporary test volume does not support hole punching")
        }
    }

    private func node(named name: String, in result: ScanResult) throws -> DiskNode {
        try XCTUnwrap(result.nodes.first { $0.name == name })
    }

    private func signature(of result: ScanResult) -> [String] {
        result.nodes.map {
            "\($0.name)|\($0.isDirectory)|\($0.isSymlink)|\($0.logicalBytes)|\($0.allocatedBytes)|\($0.modified.timeIntervalSince1970)|\($0.device)|\($0.inode)"
        }.sorted()
    }
}

private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []

    var values: [ScanProgress] {
        lock.withLock { updates }
    }

    func append(_ update: ScanProgress) {
        lock.withLock { updates.append(update) }
    }
}

private extension POSIXError {
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
