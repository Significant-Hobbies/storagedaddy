import XCTest
@testable import DiskCore

final class DuplicateRetentionTests: XCTestCase {
    func testKeepsDatesAndUsesDeterministicTiesAcrossAllGroups() {
        let scan = ScanResult(rootPath: "/fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true, children: [1, 2, 3, 4]),
            DiskNode(id: 1, parent: 0, name: "z", isDirectory: false, modified: Date(timeIntervalSince1970: 1)),
            DiskNode(id: 2, parent: 0, name: "a", isDirectory: false, modified: Date(timeIntervalSince1970: 2)),
            DiskNode(id: 3, parent: 0, name: "c", isDirectory: false, modified: Date(timeIntervalSince1970: 3)),
            DiskNode(id: 4, parent: 0, name: "b", isDirectory: false, modified: Date(timeIntervalSince1970: 3))
        ])
        let groups = [DuplicateGroup(id: "first", nodeIDs: [1, 2], wastedBytes: 1), DuplicateGroup(id: "second", nodeIDs: [3, 4], wastedBytes: 1)]
        XCTAssertEqual(DuplicateRetention.removals(in: groups, scan: scan, keepNewest: true), [1, 3])
        XCTAssertEqual(DuplicateRetention.removals(in: groups, scan: scan, keepNewest: false), [2, 3])
        XCTAssertTrue(DuplicateRetention.removals(in: [DuplicateGroup(id: "invalid", nodeIDs: [1, 99], wastedBytes: 1)], scan: scan, keepNewest: true).isEmpty)
    }
}
