import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// Background lifecycle shared by the Daddy apps that keep working after their
// window closes: launch at login and opt-in completion notices. The quit review
// lives in DaddyVisualCore. This source is copied into each app so native
// packages remain independently buildable.

/// Opt-in local notice when long work finishes while no app window is visible.
@MainActor
enum DaddyCompletionNotices {
    static let preferenceKey = "notifyOnBackgroundCompletion"

    /// UNUserNotificationCenter requires a bundled app; tests and `swift run` have none.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    /// Stores the preference only when macOS grants notification access.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) async -> Bool {
        guard enabled, isAvailable else {
            defaults.set(false, forKey: preferenceKey)
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        defaults.set(granted, forKey: preferenceKey)
        return granted
    }

    /// A visible window already shows the result, so only background completions notify.
    static func shouldPost(enabled: Bool, hasVisibleWindow: Bool) -> Bool {
        enabled && !hasVisibleWindow
    }

    static var hasVisibleAppWindow: Bool {
        NSApplication.shared.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    }

    static func postIfWindowHidden(title: String, body: String, defaults: UserDefaults = .standard) {
        guard isAvailable,
              shouldPost(enabled: isEnabled(defaults), hasVisibleWindow: hasVisibleAppWindow)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Registers the app itself as a login item. Nothing changes until the owner
/// turns the menu toggle on; failures leave the reported system state visible.
@MainActor
final class DaddyLaunchAtLogin: ObservableObject {
    struct Service {
        var status: () -> SMAppService.Status
        var register: () throws -> Void
        var unregister: () throws -> Void

        static var mainApp: Service {
            Service(status: { SMAppService.mainApp.status },
                    register: { try SMAppService.mainApp.register() },
                    unregister: { try SMAppService.mainApp.unregister() })
        }
    }

    static let failureMessage = "Couldn’t change the login setting. Check System Settings → General → Login Items."
    static let approvalMessage = "Allow it in System Settings → General → Login Items."

    @Published private(set) var isEnabled: Bool
    @Published private(set) var message: String?
    private let service: Service

    init(service: Service = .mainApp) {
        self.service = service
        isEnabled = service.status() == .enabled
        message = service.status() == .requiresApproval ? Self.approvalMessage : nil
    }

    func set(_ enabled: Bool) {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            message = nil
        } catch {
            message = Self.failureMessage
        }
        let status = service.status()
        isEnabled = status == .enabled
        if status == .requiresApproval { message = Self.approvalMessage }
    }
}

struct DaddyLaunchAtLoginToggle: View {
    @ObservedObject var login: DaddyLaunchAtLogin

    var body: some View {
        Toggle("Launch at Login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
        if let message = login.message { Text(message) }
    }
}

struct DaddyCompletionNoticeToggle: View {
    let title: String
    @State private var enabled = DaddyCompletionNotices.isEnabled()
    @State private var unavailable = false

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { enabled },
            set: { requested in
                Task {
                    enabled = await DaddyCompletionNotices.setEnabled(requested)
                    unavailable = requested && !enabled
                }
            }
        ))
        if unavailable { Text("Allow notifications in System Settings.") }
    }
}
