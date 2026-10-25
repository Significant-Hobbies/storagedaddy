import Darwin
import XCTest
@testable import DiskCore

final class RemovalMeasurementTests: XCTestCase {
    private func regular(_ path: Int, inode: UInt64, links: UInt32 = 1, bytes: Int64 = 100) -> LiveRemovalFact {
        LiveRemovalFact(pathIndex: path, device: 1, inode: inode, allocatedBytes: bytes, linkCount: links)
    }
    private func clone(_ path: Int, inode: UInt64, links: UInt32 = 1, volume: UInt64 = 7, group: UInt64 = 9,
                       references: UInt32 = 2, bytes: Int64 = 100, privateBytes: Int64 = 0) -> LiveRemovalFact {
        LiveRemovalFact(pathIndex: path, device: volume, inode: inode, allocatedBytes: bytes, linkCount: links,
            privateBytes: privateBytes, sharing: .shared, cloneVolumeID: volume, cloneID: group, cloneReferenceCount: references)
    }
    func testUnsharedFilesFreeTheirOwnAllocation() throws {
        var tally = LiveRemovalAccumulator(pathCount: 2)
        try tally.add(regular(0, inode: 10)); try tally.add(regular(1, inode: 11, bytes: 50))
        let result = try tally.finish()
        XCTAssertEqual(result.total.sizeBytes, 150); XCTAssertEqual(result.total.freesBytes, 150)
        XCTAssertEqual(result.paths[0].freesBytes, 100); XCTAssertEqual(result.paths[1].freesBytes, 50)
    }
    func testHardlinkOutsideSelectionKeepsBlocksButBothSelectedNamesFreeOnce() throws {
        var single = LiveRemovalAccumulator(pathCount: 1)
        try single.add(regular(0, inode: 10, links: 2))
        let alone = try single.finish()
        XCTAssertEqual(alone.total.freesBytes, 0); XCTAssertEqual(alone.total.heldElsewhereBytes, 100)
        var both = LiveRemovalAccumulator(pathCount: 2)
        try both.add(regular(0, inode: 10, links: 2)); try both.add(regular(1, inode: 10, links: 2))
        let together = try both.finish()
        XCTAssertEqual(together.total.files, 2); XCTAssertEqual(together.total.sizeBytes, 100)
        XCTAssertEqual(together.total.freesBytes, 100)
        XCTAssertEqual(together.paths[0].freesBytes, 0); XCTAssertEqual(together.paths[1].freesBytes, 0)
    }
    func testCloneOutsideSelectionIsCountedByKernelReferenceCount() throws {
        var tally = LiveRemovalAccumulator(pathCount: 2)
        try tally.add(clone(0, inode: 10, references: 3)); try tally.add(clone(1, inode: 11, references: 3))
        let result = try tally.finish()
        XCTAssertEqual(result.total.freesBytes, 0); XCTAssertEqual(result.total.heldElsewhereBytes, 100)
        XCTAssertEqual(result.total.sizeBytes, 200)
    }
    func testRemovingAllClonesFreesGroupOnceJointlyAndPerWholeFolder() throws {
        var split = LiveRemovalAccumulator(pathCount: 2)
        try split.add(clone(0, inode: 10)); try split.add(clone(1, inode: 11))
        let result = try split.finish()
        XCTAssertEqual(result.total.freesBytes, 100); XCTAssertEqual(result.total.heldElsewhereBytes, 0)
        XCTAssertEqual(result.paths.map(\.freesBytes), [0, 0])
        var sameFolder = LiveRemovalAccumulator(pathCount: 1)
        try sameFolder.add(clone(0, inode: 10)); try sameFolder.add(clone(0, inode: 11))
        XCTAssertEqual(try sameFolder.finish().paths[0].freesBytes, 100)
    }
    func testHardlinkAliasesDoNotPretendToBeExtraCloneMembers() throws {
        var tally = LiveRemovalAccumulator(pathCount: 2)
        try tally.add(clone(0, inode: 10, links: 2)); try tally.add(clone(1, inode: 10, links: 2))
        let result = try tally.finish()
        XCTAssertEqual(result.total.freesBytes, 0); XCTAssertEqual(result.total.heldElsewhereBytes, 100)
        var all = LiveRemovalAccumulator(pathCount: 2)
        try all.add(clone(0, inode: 10, links: 2)); try all.add(clone(1, inode: 10, links: 2)); try all.add(clone(1, inode: 11))
        XCTAssertEqual(try all.finish().total.freesBytes, 100)
    }
    func testCloneIDsAreScopedByRealAPFSVolume() throws {
        var tally = LiveRemovalAccumulator(pathCount: 1)
        try tally.add(clone(0, inode: 10, volume: 7)); try tally.add(clone(0, inode: 11, volume: 8))
        let result = try tally.finish()
        XCTAssertEqual(result.total.freesBytes, 0); XCTAssertEqual(result.total.heldElsewhereBytes, 200)
    }
    func testRewrittenCloneOrUnsupportedReferenceCountKeepsSharedBytesUncertain() throws {
        var tally = LiveRemovalAccumulator(pathCount: 1)
        try tally.add(clone(0, inode: 10, references: 1, privateBytes: 20))
        let result = try tally.finish()
        XCTAssertEqual(result.total.freesBytes, 20); XCTAssertEqual(result.total.uncertainBytes, 80)
        var unavailable = LiveRemovalAccumulator(pathCount: 1)
        try unavailable.add(LiveRemovalFact(pathIndex: 0, device: 1, inode: 10, allocatedBytes: 100, sharing: .unavailable))
        let unknown = try unavailable.finish()
        XCTAssertEqual(unknown.total.freesBytes, 0); XCTAssertEqual(unknown.total.uncertainBytes, 100)
    }
    func testChangingHardlinkMetadataFailsClosed() throws {
        var tally = LiveRemovalAccumulator(pathCount: 1)
        try tally.add(regular(0, inode: 10, links: 2)); try tally.add(regular(0, inode: 10, links: 3))
        XCTAssertEqual(try tally.finish().total.freesBytes, 0)
        XCTAssertTrue(tally.incomplete)
    }
    func testNativeExternalHardlinkAndNestedPathMeasurement() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("storagedaddy-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let selected = fixture.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let file = selected.appendingPathComponent("payload.bin"), outside = fixture.appendingPathComponent("outside.bin")
        try Data(repeating: 37, count: 65_536).write(to: file)
        try FileManager.default.linkItem(at: file, to: outside)
        let alone = try RemovalMeasurement.measure(paths: [selected, file])
        XCTAssertEqual(alone.nested.count, 1)
        XCTAssertEqual(alone.total.files, 1); XCTAssertEqual(alone.total.freesBytes, 0)
        XCTAssertGreaterThan(alone.total.heldElsewhereBytes, 0)
        let together = try RemovalMeasurement.measure(paths: [selected, outside])
        XCTAssertEqual(together.total.files, 2); XCTAssertEqual(together.total.sizeBytes, alone.total.sizeBytes)
        XCTAssertEqual(together.total.heldElsewhereBytes, 0)
        XCTAssertFalse(together.incomplete)
    }
    func testNativeAPFSCloneReferenceCountIncludesOutsideCopy() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("storagedaddy-clones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("first.bin"), second = fixture.appendingPathComponent("second.bin")
        try Data(repeating: 71, count: 131_072).write(to: first)
        guard clonefile(first.path, second.path, 0) == 0 else { throw XCTSkip("Clone fixture unavailable on this filesystem") }
        let alone = try RemovalMeasurement.measure(paths: [first])
        guard alone.cloneMetadata else { throw XCTSkip("APFS allocation attributes unavailable on this filesystem") }
        let together = try RemovalMeasurement.measure(paths: [first, second])
        XCTAssertGreaterThan(alone.total.heldElsewhereBytes, 0)
        XCTAssertEqual(together.total.heldElsewhereBytes, 0)
        XCTAssertGreaterThan(together.total.freesBytes, alone.total.freesBytes)
        XCTAssertFalse(together.incomplete)
    }
    func testExclusionsAndCancellationNeverBecomeCompleteZeroReclaim() throws {
        let missing = URL(fileURLWithPath: "/private/tmp/storagedaddy-nonexistent-\(UUID().uuidString)")
        XCTAssertThrowsError(try RemovalMeasurement.measure(paths: [missing], cancellationCheck: { throw CancellationError() }))
        let report = try RemovalMeasurement.measure(paths: [missing])
        XCTAssertTrue(report.incomplete); XCTAssertEqual(report.missing.count, 1)
    }
}
