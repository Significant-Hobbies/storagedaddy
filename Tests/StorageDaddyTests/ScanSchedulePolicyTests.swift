import XCTest
@testable import StorageDaddy

final class ScanSchedulePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)
    func testDefaultOffAndMissingApprovalCannotRun() {
        XCTAssertEqual(decision(enabled: false), .disabled)
        XCTAssertEqual(decision(approved: false), .deferred("Choose a folder before enabling recurring scans."))
    }
    func testNotDueDoesNotRunAndExactBoundaryRunsOnce() {
        XCTAssertEqual(decision(due: now.addingTimeInterval(1)), .waiting)
        XCTAssertEqual(decision(due: now), .run)
        XCTAssertEqual(decision(due: nil), .waiting)
    }
    func testAnyActivityDefersWithoutChangingDueTime() {
        for blocker in ["Scan in progress", "Review selected files", "Export in progress", "Agent removal waiting", "Moving files", "Cache command running", "History import in progress"] {
            XCTAssertEqual(decision(block: blocker), .deferred(blocker))
        }
    }
    func testChangingCurrentRootCannotSilentlyReplaceIt() {
        guard case .deferred = decision(current: "/other") else { return XCTFail("Changing the active root must defer the saved schedule") }
        XCTAssertEqual(decision(current: nil), .run, "A restarted app can resume its explicitly approved folder")
        XCTAssertEqual(decision(current: "/approved"), .run)
    }
    func testNextRunStartsAfterCompletionWithoutCatchUpBurst() {
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: now, interval: .fiveMinutes), now.addingTimeInterval(300))
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: now, interval: .fifteenMinutes), now.addingTimeInterval(900))
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: now, interval: .hourly), now.addingTimeInterval(3600))
    }
    func testIdleGateRequiresMeasuredIdleAndRespectsBoundary() {
        XCTAssertTrue(SystemIdlePolicy.allows(requireIdle: false, minutes: 10, idleSeconds: .nan))
        XCTAssertFalse(SystemIdlePolicy.allows(requireIdle: true, minutes: 10, idleSeconds: .nan))
        XCTAssertFalse(SystemIdlePolicy.allows(requireIdle: true, minutes: 10, idleSeconds: 599))
        XCTAssertTrue(SystemIdlePolicy.allows(requireIdle: true, minutes: 10, idleSeconds: 600))
    }
    private func decision(enabled: Bool = true, approved: Bool = true, due: Date? = Date(timeIntervalSince1970: 0),
                          current: String? = "/approved", block: String? = nil) -> ScanSchedulePolicy.Decision {
        ScanSchedulePolicy.decision(enabled: enabled, hasApprovedFolder: approved, dueAt: due, now: now,
            approvedPath: approved ? "/approved" : nil, currentScanRoot: current, blockReason: block)
    }
}
