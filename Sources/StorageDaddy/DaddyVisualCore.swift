import AppKit
import SwiftUI

// The approved Daddy-series colors and control geometry. This source is copied
// into each app so native packages remain independently buildable.
enum DaddyPalette {
    static let canvas = Color.black
    static let ink = Color.white
    static let mint = Color(red: 0.42, green: 0.79, blue: 0.62)
    static let secondaryInk = Color(red: 0.78, green: 0.90, blue: 0.86)
    static let coral = Color(red: 0.90, green: 0.46, blue: 0.40)
    static let blue = Color(red: 0.33, green: 0.58, blue: 0.83)
    static let cyan = Color(red: 0.27, green: 0.70, blue: 0.75)
    static let amber = Color(red: 0.87, green: 0.67, blue: 0.28)
}

struct DaddyControlStyle: ButtonStyle {
    var prominent = false
    var hoverFeedback = false

    func makeBody(configuration: Configuration) -> some View {
        DaddyControl(
            label: configuration.label,
            prominent: prominent,
            hoverFeedback: hoverFeedback,
            isPressed: configuration.isPressed
        )
    }
}

private struct DaddyControl<Label: View>: View {
    let label: Label
    let prominent: Bool
    let hoverFeedback: Bool
    let isPressed: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? DaddyPalette.canvas : DaddyPalette.mint)
            .background(
                prominent ? DaddyPalette.mint :
                    (hoverFeedback && hovering && isEnabled ? DaddyPalette.mint.opacity(0.18) : DaddyPalette.canvas),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(DaddyPalette.mint.opacity(prominent ? 1 : 0.35), lineWidth: 1))
            .opacity(isEnabled ? (isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

// Native menu bar actions shared by the four independently packaged apps.
// Each app owns the status and task actions between these controls.
struct DaddyMenuOpenButton: View {
    let appName: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open \(appName)") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

struct DaddyMenuQuitButton: View {
    let appName: String

    var body: some View {
        Button("Quit \(appName)") { NSApplication.shared.terminate(nil) }
    }
}

struct DaddyMenuStatus: View {
    let message: String

    var body: some View {
        Text(message).accessibilityLabel("Status: \(message)")
    }
}

@MainActor
enum DaddyQuitReview {
    static func shouldQuit(appName: String, activeWork: String?) -> Bool {
        guard let activeWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit \(appName)?"
        alert.informativeText = "\(activeWork) Quitting now may interrupt it."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

