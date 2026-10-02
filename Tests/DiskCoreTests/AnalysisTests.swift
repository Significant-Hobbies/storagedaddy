import Foundation
import Darwin
import XCTest
@testable import DiskCore

final class AnalysisTests: XCTestCase {
    func testDuplicateFinderUsesContentsAndNotNames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeDirectory("left")
        try fixture.makeDirectory("right")
        try fixture.makeDirectory("other")
        try fixture.write("left/report.txt", data: Data("same contents".utf8))
        try fixture.write("right/report.txt", data: Data("same contents".utf8))
        try fixture.write("other/report.txt", data: Data("different contents".utf8))

        let nodes = try [
            fixture.node(id: 0, parent: nil, name: "", path: "", directory: true),
            fixture.node(id: 1, parent: 0, name: "left", path: "left", directory: true),
            fixture.node(id: 2, parent: 0, name: "right", path: "right", directory: true),
            fixture.node(id: 3, parent: 0, name: "other", path: "other", directory: true),
            fixture.node(id: 4, parent: 1, name: "report.txt", path: "left/report.txt", useModified: false),
            fixture.node(id: 5, parent: 2, name: "report.txt", path: "right/report.txt", useModified: false),
            fixture.node(id: 6, parent: 3, name: "report.txt", path: "other/report.txt", useModified: false)
        ]

        let groups = try await DuplicateFinder.find(in: ScanResult(rootPath: fixture.root.path, nodes: nodes))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].nodeIDs, [4, 5])
        XCTAssertEqual(groups[0].wastedBytes, Int64("same contents".utf8.count))
    }

    func testDuplicateFinderDoesNotReportHardLinksTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("original.bin", data: Data(repeating: 7, count: 4096))
        try FileManager.default.linkItem(
            at: fixture.url("original.bin"),
            to: fixture.url("hard-link.bin")
        )

        let nodes = try [
            fixture.node(id: 0, parent: nil, name: "", path: "", directory: true),
            fixture.node(id: 1, parent: 0, name: "original.bin", path: "original.bin", useModified: false),
            fixture.node(id: 2, parent: 0, name: "hard-link.bin", path: "hard-link.bin", useModified: false)
        ]
        let scan = ScanResult(rootPath: fixture.root.path, nodes: nodes)
        let groups = try await DuplicateFinder.find(in: scan)
        XCTAssertTrue(groups.isEmpty)
    }

    func testDuplicateFinderIncludesIndependentZeroLengthFiles() async throws {
        let fixture = try Fixture()
        try fixture.write("empty-a.bin", data: Data())
        try fixture.write("empty-b.bin", data: Data())
        let nodes = try [
            fixture.node(id: 0, parent: nil, name: "", path: "", directory: true),
            fixture.node(id: 1, parent: 0, name: "empty-a.bin", path: "empty-a.bin", useModified: false),
            fixture.node(id: 2, parent: 0, name: "empty-b.bin", path: "empty-b.bin", useModified: false)
        ]
        let groups = try await DuplicateFinder.find(in: ScanResult(rootPath: fixture.root.path, nodes: nodes))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.nodeIDs, [1, 2])
        XCTAssertEqual(groups.first?.wastedBytes, 0)
    }

    func testDuplicateFinderIncludesAPFSClonesWhenSupported() async throws {
        let fixture = try Fixture()
        try fixture.write("original.bin", data: Data(repeating: 17, count: 16384))
        let status = clonefile(fixture.url("original.bin").path, fixture.url("clone.bin").path, 0)
        if status != 0 {
            let code = errno
            guard [ENOTSUP, EXDEV, ENOSYS, EINVAL].contains(code) else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            throw XCTSkip("clonefile unavailable on this fixture filesystem (errno \(code))")
        }
        let nodes = try [
            fixture.node(id: 0, parent: nil, name: "", path: "", directory: true),
            fixture.node(id: 1, parent: 0, name: "original.bin", path: "original.bin", useModified: false),
            fixture.node(id: 2, parent: 0, name: "clone.bin", path: "clone.bin", useModified: false)
        ]
        XCTAssertNotEqual(nodes[1].inode, nodes[2].inode)
        let groups = try await DuplicateFinder.find(in: ScanResult(rootPath: fixture.root.path, nodes: nodes))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.nodeIDs, [1, 2])
        // Content equality does not establish that shared blocks can be reclaimed.
    }

    func testCleanupSafetyRejectsRootEscapesAndProtectedContainers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("safe.txt", data: Data("safe".utf8))
        let expected = try fixture.node(id: 1, parent: 0, name: "safe.txt", path: "safe.txt")
        XCTAssertNoThrow(try CleanupSafety.validate(url: fixture.url("safe.txt"), expected: expected, root: fixture.root))

        XCTAssertThrowsError(try CleanupSafety.validate(url: fixture.root, expected: expected, root: fixture.root))
        XCTAssertThrowsError(try CleanupSafety.validate(
            url: fixture.root.appendingPathComponent("../outside.txt"), expected: expected, root: fixture.root
        ))

        try fixture.makeDirectory("Library/Containers/App")
        try fixture.write("Library/Containers/App/data", data: Data("secret".utf8))
        let protected = try fixture.node(
            id: 2, parent: 0, name: "data", path: "Library/Containers/App/data"
        )
        XCTAssertThrowsError(try CleanupSafety.validate(
            url: fixture.url("Library/Containers/App/data"), expected: protected, root: fixture.root
        ))

        try FileManager.default.createSymbolicLink(
            at: fixture.url("link"), withDestinationURL: fixture.url("safe.txt")
        )
        XCTAssertThrowsError(try CleanupSafety.validate(
            url: fixture.url("link"), expected: expected, root: fixture.root
        ))
    }

    func testCleanupSafetyAllowsDirectoryWithAggregateScanSize() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeDirectory("folder")
        try fixture.write("folder/item.bin", data: Data(repeating: 1, count: 32))
        let scan = try await DiskScanner.scan(root: fixture.root, backend: .foundation)
        let expected = try XCTUnwrap(scan.nodes.first { $0.name == "folder" && $0.isDirectory })

        XCTAssertNoThrow(try CleanupSafety.validate(
            url: scan.url(for: expected.id), expected: expected, root: fixture.root
        ))
    }

    func testCleanupSafetyAllowsStartupDataFirmlinkWithoutTrashingAnything() throws {
        let fixture = try Fixture(base: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/StorageDaddyTests"))
        try fixture.write("safe.txt", data: Data("firmlink fixture".utf8))
        let original = fixture.url("safe.txt").resolvingSymlinksInPath()
        let dataRoot = URL(fileURLWithPath: "/System/Volumes/Data")
        let physical = try XCTUnwrap(realpath(original.path, nil))
        defer { free(physical) }
        let alias = dataRoot.appendingPathComponent(String(cString: physical))
        guard FileManager.default.fileExists(atPath: alias.path) else {
            throw XCTSkip("Requires the macOS startup Data volume")
        }
        let expected = try fixture.node(id: 1, parent: 0, name: "safe.txt", path: "safe.txt")
        XCTAssertEqual(alias.resolvingSymlinksInPath().path, original.path)
        XCTAssertNoThrow(try CleanupSafety.validate(url: alias, expected: expected, root: dataRoot))
        XCTAssertThrowsError(try CleanupSafety.validate(url: alias, expected: expected, root: alias))

        try FileManager.default.createSymbolicLink(at: fixture.url("linked-folder"), withDestinationURL: fixture.root)
        let linked = alias.deletingLastPathComponent().appendingPathComponent("linked-folder/safe.txt")
        XCTAssertThrowsError(try CleanupSafety.validate(url: linked, expected: expected, root: dataRoot))

        try fixture.makeDirectory("Library/Containers/Test")
        let protected = try fixture.node(id: 2, parent: 0, name: "Test", path: "Library/Containers/Test", directory: true)
        XCTAssertThrowsError(try CleanupSafety.validate(
            url: alias.deletingLastPathComponent().appendingPathComponent("Library/Containers/Test"),
            expected: protected, root: dataRoot
        ))
    }

    func testCleanupSafetyRejectsAncestorSymlinkEvenInsideRoot() throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("real")
        try fixture.write("real/safe.txt", data: Data("safe".utf8))
        try FileManager.default.createSymbolicLink(at: fixture.url("alias"), withDestinationURL: fixture.url("real"))
        let expected = try fixture.node(id: 1, parent: 0, name: "safe.txt", path: "real/safe.txt")
        XCTAssertThrowsError(try CleanupSafety.validate(url: fixture.url("alias/safe.txt"), expected: expected, root: fixture.root))
    }

    func testCleanupSafetyProtectsSystemRootsWithoutReadingThem() {
        let applications = URL(fileURLWithPath: "/Applications")
        let expected = DiskNode(id: 1, parent: 0, name: "Applications", isDirectory: true)
        XCTAssertThrowsError(try CleanupSafety.validate(
            url: applications, expected: expected, root: applications
        ))
    }

    func testSnapshotComparisonUsesTopLevelUnion() {
        let old = ScanResult(rootPath: "/tmp/fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "", isDirectory: true),
            DiskNode(id: 1, parent: 0, name: "A", isDirectory: true, allocatedBytes: 10),
            DiskNode(id: 2, parent: 0, name: "B", isDirectory: true, allocatedBytes: 20)
        ])
        let new = ScanResult(rootPath: "/tmp/fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "", isDirectory: true),
            DiskNode(id: 1, parent: 0, name: "A", isDirectory: true, allocatedBytes: 15),
            DiskNode(id: 3, parent: 0, name: "C", isDirectory: true, allocatedBytes: 5)
        ])

        let deltas = SnapshotComparison.compare(old, new)
        XCTAssertEqual(deltas.map { $0.name }, ["A", "B", "C"])
        XCTAssertEqual(deltas.map { $0.change }, [5, -20, 5])
    }
}

private final class Fixture {
    let root: URL
    private let fileManager = FileManager.default

    init(base: URL = FileManager.default.temporaryDirectory) throws {
        root = base.appendingPathComponent("DiskBuddyAnalysis-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func makeDirectory(_ relativePath: String) throws {
        try fileManager.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, data: Data) throws {
        let fileURL = url(relativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    func node(id: Int, parent: Int?, name: String, path: String, directory: Bool = false, useModified: Bool = true) throws -> DiskNode {
        let fileURL = url(path)
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { throw POSIXError(.EIO) }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return DiskNode(
            id: id,
            parent: parent,
            name: name,
            isDirectory: directory,
            logicalBytes: size,
            allocatedBytes: size,
            modified: useModified ? modified : .distantPast,
            device: device,
            inode: inode
        )
    }

    func remove() {
        // Keep fixture files for inspection; no deletion during this task.
    }
}
