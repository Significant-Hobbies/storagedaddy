import XCTest
@testable import DiskCore

final class StorageMapIndexTests: XCTestCase {
    func testCancelledScanDoesNotReturnAnIndex() {
        let scan = ScanResult(rootPath: "/fixture", nodes: [DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)])
        XCTAssertThrowsError(try StorageMapIndex(scan: scan, groups: [], cancellationCheck: { throw CancellationError() }))
    }
    func testKindsReuseOwnershipAndRequireProjectShape() {
        let scan = ScanResult(rootPath: "/fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true, children: [1, 6, 8]),
            DiskNode(id: 1, parent: 0, name: "project", isDirectory: true, children: [2, 3, 5]),
            DiskNode(id: 2, parent: 1, name: "package.json", isDirectory: false),
            DiskNode(id: 3, parent: 1, name: "node_modules", isDirectory: true, allocatedBytes: 10, children: [4]),
            DiskNode(id: 4, parent: 3, name: "dependency.js", isDirectory: false, allocatedBytes: 10),
            DiskNode(id: 5, parent: 1, name: "photo.png", isDirectory: false),
            DiskNode(id: 6, parent: 0, name: ".git", isDirectory: true, allocatedBytes: 8, children: [7]),
            DiskNode(id: 7, parent: 6, name: "objects", isDirectory: false, allocatedBytes: 8),
            DiskNode(id: 8, parent: 0, name: "target", isDirectory: true)
        ])
        let index = StorageMapIndex(scan: scan)
        XCTAssertEqual(index.kinds[1], .code)
        XCTAssertEqual(index.kinds[3], .packages)
        XCTAssertEqual(index.kinds[4], .packages)
        XCTAssertEqual(index.kinds[5], .media)
        XCTAssertEqual(index.kinds[6], .git)
        XCTAssertEqual(index.kinds[7], .git)
        XCTAssertEqual(index.fileCounts[0], 4)
        XCTAssertEqual(index.fileCounts[1], 3)
        XCTAssertEqual(index.fileCounts[8], 0)
        XCTAssertTrue(index.reviewCandidates.contains(3))
        XCTAssertFalse(index.reviewCandidates.contains(6))
    }

    func testGenericNamesDoNotEstablishProjectOrCleanupEligibility() {
        let scan = ScanResult(rootPath: "/fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true, children: [1, 3]),
            DiskNode(id: 1, parent: 0, name: "ordinary", isDirectory: true, children: [2]),
            DiskNode(id: 2, parent: 1, name: "Assets", isDirectory: true),
            DiskNode(id: 3, parent: 0, name: "old-notes.md", isDirectory: false)
        ])
        let index = StorageMapIndex(scan: scan)
        XCTAssertEqual(index.kinds[1], .generic)
        XCTAssertEqual(index.kinds[3], .documents)
        XCTAssertTrue(index.reviewCandidates.isEmpty)
        XCTAssertEqual(index.fileCounts[0], 1)
    }
}
