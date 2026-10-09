import XCTest
#if canImport(ContextDaddy)
@testable import ContextDaddy
#elseif canImport(StorageDaddy)
@testable import StorageDaddy
#elseif canImport(PerformanceDaddy)
@testable import PerformanceDaddy
#elseif canImport(BrowserDaddy)
@testable import BrowserDaddy
#endif

final class DaddyAppUpdatesTests: XCTestCase {
    @MainActor func testBusyBackgroundCheckRetriesOnlyOnceAfterIdle() async {
        let gate = DaddyUpdateGate()
        XCTAssertFalse(gate.allowCheck(isIdle: false, background: true))
        var checks = 0
        gate.resumeIfIdle(false) { checks += 1 }
        XCTAssertEqual(checks, 0)
        gate.resumeIfIdle(true) { checks += 1 }
        gate.resumeIfIdle(true) { checks += 1 }
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(gate.pendingCheck)
    }

    @MainActor func testBusyManualCheckDoesNotCreateBackgroundRetry() async {
        let gate = DaddyUpdateGate()
        XCTAssertFalse(gate.allowCheck(isIdle: false, background: false))
        var checks = 0
        gate.resumeIfIdle(true) { checks += 1 }
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(gate.allowCheck(isIdle: true, background: false))
    }

    @MainActor func testApprovedInstallWaitsAndTakesPriorityOverQueuedCheck() async {
        let gate = DaddyUpdateGate()
        var installs = 0
        var checks = 0
        XCTAssertFalse(gate.allowCheck(isIdle: false, background: true))
        XCTAssertTrue(gate.postponeInstall(isIdle: false) { installs += 1 })
        XCTAssertTrue(gate.waitingForIdle)
        gate.resumeIfIdle(false) { checks += 1 }
        XCTAssertEqual(installs, 0)
        gate.resumeIfIdle(true) { checks += 1 }
        gate.resumeIfIdle(true) { checks += 1 }
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(checks, 0)
        XCTAssertFalse(gate.waitingForIdle)
    }

    @MainActor func testIdleInstallRemainsWithSparkle() async {
        let gate = DaddyUpdateGate()
        var installs = 0
        XCTAssertFalse(gate.postponeInstall(isIdle: true) { installs += 1 })
        gate.resumeIfIdle(true) {}
        XCTAssertEqual(installs, 0)
    }

    @MainActor func testConfigurationRequiresKeyHTTPSAndOwnerConfirmedInstall() async {
        var info: [String: Any] = ["SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
                                   "SUFeedURL": "https://example.com/updates/appcast.xml",
                                   "SUAutomaticallyUpdate": false, "SUAllowsAutomaticUpdates": false]
        XCTAssertTrue(DaddyAppUpdates.hasConfiguration(info))
        XCTAssertFalse(DaddyAppUpdates.hasConfiguration([:]))
        info["SUAutomaticallyUpdate"] = true
        XCTAssertFalse(DaddyAppUpdates.hasConfiguration(info))
        info["SUAutomaticallyUpdate"] = false
        info["SUFeedURL"] = "http://example.com/updates/appcast.xml"
        XCTAssertFalse(DaddyAppUpdates.hasConfiguration(info))
        info["SUFeedURL"] = "https://example.com/updates/appcast.xml"
        info["SUPublicEDKey"] = "invalid"
        XCTAssertFalse(DaddyAppUpdates.hasConfiguration(info))
    }
}
