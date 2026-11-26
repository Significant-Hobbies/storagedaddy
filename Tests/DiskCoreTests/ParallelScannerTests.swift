import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class ParallelScannerTests: XCTestCase {
    func testStartupDataUsesVolumeReadersEvenWhenParentDeviceMatches() {
        XCTAssertEqual(DiskScanner.automaticParallelism(rootPath: "/System/Volumes/Data", rootDevice: 1, parentDevice: 1, processorCount: 18), 16)
        XCTAssertEqual(DiskScanner.automaticParallelism(rootPath: "/System/Volumes/Data/Users", rootDevice: 1, parentDevice: 1, processorCount: 18), 4)
        XCTAssertEqual(DiskScanner.automaticParallelism(rootPath: "/", rootDevice: 1, parentDevice: 1, processorCount: 8), 8)
        XCTAssertEqual(DiskScanner.automaticParallelism(rootPath: "/Volumes/External", rootDevice: 2, parentDevice: 1, processorCount: 18), 16)
        XCTAssertEqual(DiskScanner.automaticParallelism(rootPath: "/System/Volumes/Data", rootDevice: 1, parentDevice: nil, processorCount: 2), 2)
    }

    func testParallelScanMatchesSequentialTopologyAndHardLinkOwnership() async throws {
        let fixture = try ParallelFixture()
        let foundation = try await DiskScanner.scan(root: fixture.root, backend: .foundation)
        let bulk = try await DiskScanner.scan(root: fixture.root, backend: .bulk)

        XCTAssertEqual(orderedSignature(bulk), orderedSignature(foundation))
        XCTAssertEqual(bulk.skipped, foundation.skipped)
        XCTAssertEqual(bulk.incompleteEvidence, foundation.incompleteEvidence)

        for workers in [1, 4, 8] {
            let first = try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: workers)
            let second = try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: workers)
            XCTAssertEqual(orderedSignature(first), orderedSignature(foundation), "parallelism \(workers)")
            XCTAssertEqual(orderedSignature(second), orderedSignature(first), "repeat parallelism \(workers)")
            XCTAssertEqual(first.skipped, foundation.skipped)
            XCTAssertEqual(first.incompleteEvidence, foundation.incompleteEvidence)
            XCTAssertEqual(hardLinkOwners(first), hardLinkOwners(foundation))
        }

        let progress = ParallelProgressSink()
        let result = try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: 8) {
            progress.append($0)
        }
        let final = try XCTUnwrap(progress.values.last)
        XCTAssertEqual(final.entries, result.nodes.count)
        XCTAssertEqual(final.allocatedBytes, result.nodes[0].allocatedBytes)
        XCTAssertEqual(final.logicalBytes, result.nodes[0].logicalBytes)
        XCTAssertEqual(final.files, result.nodes.filter { !$0.isDirectory && !$0.isSymlink }.count)
        XCTAssertEqual(final.skipped, result.skipped)
        XCTAssertLessThanOrEqual(final.locations.count, 8)
    }

    func testSimultaneousScansMakeProgressWithoutBlockingSwiftTasks() async throws {
        let fixture = try ParallelFixture()
        let root = fixture.root
        let reference = try await DiskScanner.scan(root: root, backend: .foundation)
        try await withThrowingTaskGroup(of: ScanResult.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await DiskScanner.scan(root: root, parallelism: 2) { progress in
                        if progress.entries == 1 {
                            XCTAssertFalse(withUnsafeCurrentTask { $0 != nil }, "Scanner waits must run outside Swift tasks")
                        }
                    }
                }
            }
            var finished = 0
            for try await result in group {
                finished += 1
                XCTAssertEqual(orderedSignature(result), orderedSignature(reference))
            }
            XCTAssertEqual(finished, 8)
        }
    }

    func testCancellationStopsParallelTraversal() async throws {
        let fixture = try ParallelFixture(extraFilesPerDirectory: 80)
        let holder = ScanTaskHolder()
        let task = Task {
            try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: 8) { update in
                if update.entries >= 128 { holder.cancel() }
            }
        }
        holder.set(task)
        do {
            _ = try await task.value
            XCTFail("expected cancellation during parallel traversal")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellationFromRootProgressStopsBeforeParallelTraversal() async throws {
        let fixture = try ParallelFixture()
        let holder = ScanTaskHolder()
        let task = Task {
            try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: 8) { update in
                if update.entries == 1 { holder.cancel() }
            }
        }
        holder.set(task)
        do {
            _ = try await task.value
            XCTFail("expected cancellation after the root progress update")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testHighConcurrencyHandlesMixedWideAndEmptyDirectoriesDeterministically() async throws {
        let fixture = try ParallelPoolFixture()
        let reference = try await DiskScanner.scan(root: fixture.root, backend: .foundation)
        let first = try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: 64)
        let second = try await DiskScanner.scan(root: fixture.root, backend: .parallel, parallelism: 64)

        XCTAssertEqual(orderedSignature(first), orderedSignature(reference))
        XCTAssertEqual(orderedSignature(second), orderedSignature(first))
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.errors, [])
    }

    private func orderedSignature(_ scan: ScanResult) -> [String] {
        scan.nodes.map { node in
            let path = scan.url(for: node.id).standardizedFileURL.path
            let children = node.children.map(String.init).joined(separator: ",")
            return "\(node.id)|\(node.parent.map(String.init) ?? "nil")|\(children)|\(path)|\(node.isDirectory)|\(node.isSymlink)|\(node.logicalBytes)|\(node.allocatedBytes)|\(node.device)|\(node.inode)|\(node.modified.timeIntervalSince1970)"
        }
    }

    private func hardLinkOwners(_ scan: ScanResult) -> [String] {
        let groups = Dictionary(grouping: scan.nodes.filter { !$0.isDirectory && !$0.isSymlink && $0.inode != 0 }) {
            "\($0.device):\($0.inode)"
        }
        return groups.values.filter { $0.count > 1 }.map { nodes in
            nodes.sorted { $0.id < $1.id }.map {
                "\(scan.url(for: $0.id).path)=\($0.allocatedBytes)"
            }.joined(separator: "|")
        }.sorted()
    }
}

private final class ParallelPoolFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageDaddy-ParallelPool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in 0..<96 {
            let branch = root.appendingPathComponent(String(format: "directory-%03d", directory), isDirectory: true)
            try FileManager.default.createDirectory(at: branch.appendingPathComponent("empty-child"), withIntermediateDirectories: true)
            guard directory.isMultiple(of: 3) else { continue }
            for file in 0..<128 {
                try Data([UInt8(directory), UInt8(file)]).write(
                    to: branch.appendingPathComponent(String(format: "wide-%03d.bin", file))
                )
            }
        }
    }
}

private final class ParallelFixture {
    let root: URL

    init(extraFilesPerDirectory: Int = 3) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageDaddy-ParallelScanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for directory in 0..<40 {
            let branch = root.appendingPathComponent(String(format: "branch-%02d/nested", directory), isDirectory: true)
            try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
            for file in 0..<extraFilesPerDirectory {
                try Data([UInt8(directory), UInt8(file % 251)]).write(to: branch.appendingPathComponent(String(format: "file-%03d.bin", file)))
            }
        }

        let original = root.appendingPathComponent("branch-00/nested/file-000.bin")
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("root-hardlink.bin"))
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("branch-20/nested/sibling-hardlink.bin"))
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("branch-39/nested/late-hardlink.bin"))

        let sparse = root.appendingPathComponent("branch-10/nested/sparse.bin")
        let descriptor = open(sparse.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, 16 * 1024 * 1024) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try Data([1]).write(to: root.appendingPathComponent(".env.parallel"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("branch-07/.ssh"), withIntermediateDirectories: true)
        try Data([2]).write(to: root.appendingPathComponent("branch-07/.ssh/id_test"))
        XCTAssertEqual(symlink("branch-00", root.appendingPathComponent("directory-loop").path), 0)
        XCTAssertEqual(symlink("missing-target", root.appendingPathComponent("dangling-link").path), 0)
    }
}

private final class ParallelProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []

    var values: [ScanProgress] { lock.withLock { updates } }
    func append(_ update: ScanProgress) { lock.withLock { updates.append(update) } }
}

private final class ScanTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ScanResult, Error>?
    private var cancellationRequested = false

    func set(_ task: Task<ScanResult, Error>) {
        lock.withLock {
            self.task = task
            if cancellationRequested { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            task?.cancel()
        }
    }
}
