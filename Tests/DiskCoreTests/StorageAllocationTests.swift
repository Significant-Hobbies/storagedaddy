import Foundation
import XCTest
@testable import DiskCore

final class StorageAllocationTests: XCTestCase {
    func testLegacyUnavailableAndIncompleteMeasurementsStayUnknown() throws {
        var scan = fixture()
        XCTAssertNil(StorageAllocationIndex(scan: scan).summary(for: scan.nodes[0]).exclusiveBytes)
        scan.fileAllocationDetails = [.init(nodeID: 2, reportedBytes: 100, privateBytes: nil, sharesStorage: true, linkCount: 1)]
        XCTAssertNil(StorageAllocationIndex(scan: scan).summary(for: scan.nodes[0]).exclusiveBytes)
        scan.fileAllocationDetails = [.init(nodeID: 2, reportedBytes: 100, privateBytes: 0, sharesStorage: true, linkCount: 1)]
        let index = StorageAllocationIndex(scan: scan)
        XCTAssertEqual(index.summary(for: scan.nodes[0]).exclusiveBytes, 20)
        XCTAssertEqual(index.summary(for: scan.nodes[1]).exclusiveBytes, 20)
        XCTAssertEqual(index.summary(for: scan.nodes[0]).sharedFiles, 1)
        scan.nodes[1].isScanIncomplete = true
        XCTAssertNil(index.summary(for: scan.nodes[1]).exclusiveBytes)
        let encoded = try JSONEncoder().encode(scan)
        XCTAssertEqual(try JSONDecoder().decode(ScanResult.self, from: encoded).fileAllocationDetails, scan.fileAllocationDetails)
        XCTAssertNil(SnapshotArchive.compact(scan).fileAllocationDetails, "Compact historical trees cannot retain leaf measurements")
    }

    func testHardLinksDoNotPromiseExclusiveRecoveryAndBadArchivesAreRejected() throws {
        var scan = fixture()
        scan.fileAllocationDetails = [.init(nodeID: 2, reportedBytes: 100, privateBytes: 100, sharesStorage: true, linkCount: 2)]
        XCTAssertEqual(StorageAllocationIndex(scan: scan).summary(for: scan.nodes[0]).exclusiveBytes, 20)
        try SnapshotArchive.validate(scan)
        scan.fileAllocationDetails = [.init(nodeID: 2, reportedBytes: 100, privateBytes: 101, sharesStorage: true, linkCount: 1)]
        XCTAssertThrowsError(try SnapshotArchive.validate(scan))
        scan.fileAllocationDetails = [.init(nodeID: 99, reportedBytes: 100, privateBytes: 0, sharesStorage: true, linkCount: 1)]
        XCTAssertThrowsError(try SnapshotArchive.validate(scan))
    }

    private func fixture() -> ScanResult {
        ScanResult(rootPath: "/tmp/shared-fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "root", isDirectory: true, allocatedBytes: 120, children: [1]),
            DiskNode(id: 1, parent: 0, name: "folder", isDirectory: true, allocatedBytes: 120, children: [2, 3]),
            DiskNode(id: 2, parent: 1, name: "shared", isDirectory: false, allocatedBytes: 100),
            DiskNode(id: 3, parent: 1, name: "private", isDirectory: false, allocatedBytes: 20)
        ])
    }
}
