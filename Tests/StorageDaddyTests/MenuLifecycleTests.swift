import AppKit
import ServiceManagement
import Testing
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct MenuLifecycleTests {
    @Test func closingLastWindowKeepsTheMenuAppAvailable() {
        let delegate = StorageDaddyAppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
        #expect(DaddyQuitReview.shouldQuit(appName: "StorageDaddy", activeWork: nil))
    }

    @Test func menuDoesNotClaimAScanBeforeOneRuns() {
        let model = ExplorerModel()
        #expect(!model.isScanning)
        #expect(model.menuStatus == "No scan yet")
        #expect(model.activeWorkDescription == nil)
    }

    @Test func quitReviewCoversEveryStorageOperation() {
        let model = ExplorerModel()
        let flags: [ReferenceWritableKeyPath<ExplorerModel, Bool>] = [\.busy, \.snapshotBusy]
        for flag in flags {
            model[keyPath: flag] = true
            #expect(model.activeWorkDescription == "A storage operation is still running.")
            #expect(model.menuStatus == "Storage operation in progress")
            model[keyPath: flag] = false
            #expect(model.activeWorkDescription == nil)
        }
        model.conversationArchive.busy = true
        #expect(model.activeWorkDescription == "A conversation export is still running.")
        model.conversationArchive.busy = false
        #expect(model.activeWorkDescription == nil)
    }

    @Test func completionNoticesPostOnlyWhenEnabledAndNoWindowIsVisible() async throws {
        #expect(DaddyCompletionNotices.shouldPost(enabled: true, hasVisibleWindow: false))
        #expect(!DaddyCompletionNotices.shouldPost(enabled: true, hasVisibleWindow: true))
        #expect(!DaddyCompletionNotices.shouldPost(enabled: false, hasVisibleWindow: false))
        let suite = "StorageDaddy-notices-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!DaddyCompletionNotices.isAvailable)
        #expect(await DaddyCompletionNotices.setEnabled(true, defaults: defaults) == false)
        #expect(!DaddyCompletionNotices.isEnabled(defaults))
    }

    @Test func launchAtLoginReflectsTheSystemStateAfterEachChange() {
        var status = SMAppService.Status.notRegistered
        var failRegister = false
        var registeredStatus = SMAppService.Status.enabled
        let login = DaddyLaunchAtLogin(service: .init(
            status: { status },
            register: {
                if failRegister { throw CocoaError(.featureUnsupported) }
                status = registeredStatus
            },
            unregister: { status = .notRegistered }
        ))
        #expect(!login.isEnabled)
        login.set(true)
        #expect(login.isEnabled && login.message == nil)
        login.set(false)
        #expect(!login.isEnabled)
        failRegister = true
        login.set(true)
        #expect(!login.isEnabled && login.message == DaddyLaunchAtLogin.failureMessage)
        failRegister = false
        registeredStatus = .requiresApproval
        login.set(true)
        #expect(!login.isEnabled && login.message == DaddyLaunchAtLogin.approvalMessage)
    }
}
