// Canonical source: saas-maker/tooling/daddy-macos/shared/DaddyAppUpdates.swift.
// Copy into each app; candidate checks reject drift. App idle rules stay local.
import AppKit
import Combine
import Sparkle
import SwiftUI

/// Keeps background retries and an owner-approved install separate. An install
/// takes priority over a queued check, and each callback is consumed once.
@MainActor
final class DaddyUpdateGate {
    private(set) var pendingCheck = false
    private var deferredInstall: (() -> Void)?
    var waitingForIdle: Bool { deferredInstall != nil }

    func allowCheck(isIdle: Bool, background: Bool) -> Bool {
        if isIdle { return true }
        if background { pendingCheck = true }
        return false
    }

    func postponeInstall(isIdle: Bool, install: @escaping () -> Void) -> Bool {
        guard !isIdle else { return false }
        deferredInstall = install
        return true
    }

    func resumeIfIdle(_ isIdle: Bool, check: () -> Void) {
        guard isIdle else { return }
        if let install = deferredInstall {
            deferredInstall = nil
            pendingCheck = false
            install()
        } else if pendingCheck {
            pendingCheck = false
            check()
        }
    }
}

/// Automatic checks use Sparkle's stored preference; installation requires its
/// standard user confirmation. Unsigned development bundles remain inert.
@MainActor
class DaddyAppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var isAvailable = false
    @Published var automaticallyChecks = true {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    @Published private(set) var waitingForIdle = false
    private var controller: SPUStandardUpdaterController?
    private let gate = DaddyUpdateGate()
    private var idle: (() -> Bool)?
    private var subscription: AnyCancellable?
    private let appName: String
    private let busyMessage: String

    init(appName: String, busyMessage: String) {
        self.appName = appName
        self.busyMessage = busyMessage
        super.init()
    }

    static func hasConfiguration(_ info: [String: Any]) -> Bool {
        guard let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUAllowsAutomaticUpdates"] as? Bool == false else { return false }
        return true
    }

    func start(observing activity: AnyPublisher<Void, Never>, isIdle: @escaping () -> Bool) {
        guard idle == nil else { return }
        idle = isIdle
        subscription = activity.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.resumeWhenIdle()
            self?.objectWillChange.send()
        }
        guard Self.hasConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        // Reading the persisted preference must not reset Sparkle's check cycle.
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        isAvailable = true
        controller.startUpdater()
    }

    var isIdle: Bool { idle?() ?? false }
    func check() { controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard gate.allowCheck(isIdle: isIdle, background: updateCheck == .updatesInBackground) else {
            throw NSError(domain: appName + ".Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: busyMessage])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let postponed = gate.postponeInstall(isIdle: isIdle, install: installHandler)
        waitingForIdle = gate.waitingForIdle
        return postponed
    }

    private func resumeWhenIdle() {
        gate.resumeIfIdle(isIdle) { [weak self] in self?.controller?.updater.checkForUpdatesInBackground() }
        waitingForIdle = gate.waitingForIdle
    }
}

/// The app command menu uses the same controls and unavailable state everywhere.
struct DaddyUpdateMenu: View {
    @ObservedObject var updates: DaddyAppUpdates

    var body: some View {
        Button("Check for Updates…") { updates.check() }
            .disabled(!updates.canCheck || !updates.isIdle)
        Toggle("Automatically Check for Updates", isOn: $updates.automaticallyChecks)
            .disabled(!updates.isAvailable)
        if updates.waitingForIdle { Text("Update will restart when current work finishes.") }
        if !updates.isAvailable { Text("Updates require a configured signed release.") }
    }
}
