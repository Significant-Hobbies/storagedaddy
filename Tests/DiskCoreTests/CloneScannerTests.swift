import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class CloneScannerTests: XCTestCase {
    func testPureClonesAndHardLinksCountOnceAcrossBackends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddy-Clones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta", "gamma", "delta"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let original = root.appendingPathComponent("alpha/original.bin")
        let pure = root.appendingPathComponent("beta/pure-clone.bin")
        let changed = root.appendingPathComponent("gamma/changed-clone.bin")
        let changedCopy = root.appendingPathComponent("delta/changed-copy.bin")
        let independent = root.appendingPathComponent("independent.bin")
        let bytes = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        try bytes.write(to: original)
        try bytes.write(to: independent)
        try clone(original, to: pure)
        try clone(original, to: changed)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: Data([255]))
        try handle.close()
        try clone(changed, to: changedCopy)
        XCTAssertEqual(link(original.path, root.appendingPathComponent("original-link.bin").path), 0)
        XCTAssertEqual(link(pure.path, root.appendingPathComponent("beta/clone-link.bin").path), 0)

        let expected = try allocation(original) + allocation(changed) + allocation(independent)
        let reference = try await DiskScanner.scan(root: root, backend: .foundation)
        XCTAssertEqual(reference.nodes[0].allocatedBytes, expected)
        XCTAssertEqual(reference.nodes[0].logicalBytes, Int64(bytes.count * 7))
        XCTAssertEqual(reference.nodes.filter { !$0.isDirectory && $0.allocatedBytes > 0 }.count, 3)
        XCTAssertEqual(reference.skipped, 0)
        // Allocation ownership can move into a selected subtree on rescan.
        // Cleanup must compare file identities and sizes rather than that total.
        let beta = try XCTUnwrap(reference.nodes.first { $0.name == "beta" })
        try await CleanupPreflight.validate(ids: [beta.id], in: reference)

        for (backend, workers) in [(ScanBackend.bulk, 0), (.parallel, 1), (.parallel, 4), (.parallel, 8)] {
            let updates = CloneProgressSink()
            let scan = try await DiskScanner.scan(root: root, backend: backend, parallelism: workers) { updates.append($0) }
            XCTAssertEqual(signature(scan), signature(reference), "\(backend), \(workers) readers")
            XCTAssertEqual(scan.skipped, 0)
            let final = try XCTUnwrap(updates.values.last)
            XCTAssertEqual(final.allocatedBytes, expected)
            XCTAssertEqual(final.locations.reduce(Int64(0)) { $0 + $1.allocatedBytes }, expected)
            for (earlier, later) in zip(updates.values, updates.values.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier.allocatedBytes, later.allocatedBytes)
            }
        }
        // A scan containing only a clone must still show its allocation: the
        // shared original outside the selected root is not part of this scan.
        let single = try await DiskScanner.scan(root: pure)
        XCTAssertEqual(single.nodes[0].allocatedBytes, try allocation(pure))
    }

    func testPartiallySharedCloneKeepsItsReportedAllocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddy-PartialClone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.bin")
        let changed = root.appendingPathComponent("changed.bin")
        try Data(repeating: 0xA5, count: 128 * 1024).write(to: original)
        try clone(original, to: changed)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: Data([255]))
        try handle.close()
        let expected = try allocation(original) + allocation(changed)
        for backend in [ScanBackend.foundation, .bulk, .parallel] {
            let scan = try await DiskScanner.scan(root: root, backend: backend)
            XCTAssertEqual(scan.nodes[0].allocatedBytes, expected)
            XCTAssertEqual(scan.nodes.filter { !$0.isDirectory && $0.allocatedBytes > 0 }.count, 2)
        }
    }

    private func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            if errno == ENOTSUP { throw XCTSkip("test volume does not support clones") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func allocation(_ file: URL) throws -> Int64 {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw POSIXError(.EIO) }
        return Int64(info.st_blocks) * 512
    }

    private func signature(_ scan: ScanResult) -> [String] {
        scan.nodes.map { "\($0.id)|\($0.parent.map(String.init) ?? "nil")|\($0.children)|\(scan.url(for: $0.id).path)|\($0.logicalBytes)|\($0.allocatedBytes)" }
    }
}

private final class CloneProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []
    var values: [ScanProgress] { lock.withLock { updates } }
    func append(_ value: ScanProgress) { lock.withLock { updates.append(value) } }
}
