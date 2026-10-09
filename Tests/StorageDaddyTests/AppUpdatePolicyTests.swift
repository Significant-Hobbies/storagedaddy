import XCTest
@testable import StorageDaddy

final class AppUpdatePolicyTests: XCTestCase {
    @MainActor func testStorageWorkAndCleanupReviewPreventRelaunch() async {
        let model = ExplorerModel()
        let updates = AppUpdates()
        updates.start(model: model)
        XCTAssertTrue(updates.isIdle)
        for flag in [\ExplorerModel.busy, \ExplorerModel.snapshotBusy, \ExplorerModel.showCleanup] {
            model[keyPath: flag] = true
            XCTAssertFalse(updates.isIdle)
            model[keyPath: flag] = false
        }
        model.conversationArchive.busy = true
        XCTAssertFalse(updates.isIdle)
        model.conversationArchive.busy = false
        model.staged = [1]
        XCTAssertFalse(updates.isIdle)
        model.staged = []
        XCTAssertTrue(updates.isIdle)
    }
}
