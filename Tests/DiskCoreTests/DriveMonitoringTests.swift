import XCTest
@testable import DiskCore

final class DriveMonitoringTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func drive(_ free: Int64, id: String = "disk-A", total: Int64 = 100_000) -> DriveCapacity {
        DriveCapacity(id: id, name: "Test", mountPoint: "/Volumes/Test", totalBytes: total, freeBytes: free)
    }
    func testSmallDropsAccumulateAndAlertDoesNotRepeat() {
        var history = DriveMonitorHistory()
        let settings = DriveMonitorSettings(enabled: true, thresholdBytes: 1_000, thresholdPercent: 100)
        XCTAssertTrue(history.ingest([drive(50_000)], at: start, settings: settings).isEmpty)
        XCTAssertTrue(history.ingest([drive(49_500)], at: start, settings: settings).isEmpty)
        let first = history.ingest([drive(49_000)], at: start, settings: settings)
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first.first?.droppedBytes, 1_000)
        XCTAssertTrue(history.ingest([drive(49_000)], at: start, settings: settings).isEmpty)
        XCTAssertTrue(history.ingest([drive(48_500)], at: start, settings: settings).isEmpty)
        XCTAssertEqual(history.ingest([drive(48_000)], at: start, settings: settings).count, 1)
    }
    func testPercentThresholdUsesCapacityAndIncreaseResetsBaseline() {
        var history = DriveMonitorHistory()
        let settings = DriveMonitorSettings(enabled: true, thresholdBytes: 100_000, thresholdPercent: 1)
        history.ingest([drive(50_000)], at: start, settings: settings)
        history.ingest([drive(60_000)], at: start, settings: settings)
        let events = history.ingest([drive(59_000)], at: start, settings: settings)
        XCTAssertEqual(events.first?.droppedBytes, 1_000)
    }
    func testPartialRecoveryAlsoStartsNewBaseline() {
        var history = DriveMonitorHistory()
        let settings = DriveMonitorSettings(enabled: true, thresholdBytes: 1_000, thresholdPercent: 100)
        history.ingest([drive(50_000)], at: start, settings: settings)
        history.ingest([drive(49_500)], at: start, settings: settings)
        history.ingest([drive(49_750)], at: start, settings: settings)
        XCTAssertTrue(history.ingest([drive(48_900)], at: start, settings: settings).isEmpty)
        XCTAssertEqual(history.ingest([drive(48_750)], at: start, settings: settings).first?.droppedBytes, 1_000)
    }
    func testUnverifiedBSDIdentityCannotCreateReplacementDiskAlerts() {
        var history = DriveMonitorHistory()
        let settings = DriveMonitorSettings(enabled: true, thresholdBytes: 1, thresholdPercent: 1)
        history.ingest([drive(50_000, id: "unverified:disk9:/Volumes/Test")], at: start, settings: settings)
        XCTAssertTrue(history.ingest([drive(1, id: "unverified:disk9:/Volumes/Test")], at: start, settings: settings).isEmpty)
        XCTAssertEqual(history.latest.count, 1, "Capacity remains visible without alert attribution")
        XCTAssertTrue(history.points.isEmpty)
    }
    func testDriveReplacementCapacityChangeAndOptOutDoNotCreateFalseDrops() {
        var history = DriveMonitorHistory()
        let enabled = DriveMonitorSettings(enabled: true, thresholdBytes: 1, thresholdPercent: 1)
        history.ingest([drive(50_000)], at: start, settings: enabled)
        XCTAssertTrue(history.ingest([drive(1_000, id: "disk-B")], at: start, settings: enabled).isEmpty)
        XCTAssertTrue(history.ingest([drive(500, id: "disk-B", total: 50_000)], at: start, settings: enabled).isEmpty)
        let excluded = DriveMonitorSettings(enabled: true, thresholdBytes: 1, excludedDriveIDs: ["disk-B"])
        XCTAssertTrue(history.ingest([drive(1, id: "disk-B", total: 50_000)], at: start, settings: excluded).isEmpty)
        let disabled = DriveMonitorSettings(enabled: false, thresholdBytes: 1)
        XCTAssertTrue(history.ingest([drive(0, id: "disk-B", total: 50_000)], at: start, settings: disabled).isEmpty)
    }
    func testHistoryBoundsAndRestartDoesNotReuseBaseline() throws {
        var history = DriveMonitorHistory()
        let settings = DriveMonitorSettings(enabled: true, thresholdBytes: 1, thresholdPercent: 100)
        for i in 0..<2_000 { history.ingest([drive(50_000 - Int64(i))], at: start, settings: settings) }
        XCTAssertEqual(history.events.count, DriveMonitorHistory.eventLimit)
        XCTAssertEqual(history.points.count, DriveMonitorHistory.pointLimit)
        var loaded = try JSONDecoder().decode(DriveMonitorHistory.self, from: JSONEncoder().encode(history))
        loaded.boundPersistedData()
        XCTAssertTrue(loaded.ingest([drive(1)], at: start, settings: settings).isEmpty)
    }
}
