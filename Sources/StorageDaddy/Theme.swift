import SwiftUI
import SaaSMakerUI

/// Fleet typography and components with the Daddy-series canvas and evidence colors.
enum DaddyTheme {
    static let palette: SMPalette = {
        var palette = SMPalette.ink.brand(
            Color(red: 107 / 255, green: 201 / 255, blue: 158 / 255), foreground: .black
        )
        palette.background = DaddyPalette.canvas
        palette.surface = DaddyPalette.canvas
        palette.card = DaddyPalette.canvas
        palette.foreground = DaddyPalette.ink
        palette.mutedForeground = DaddyPalette.secondaryInk
        palette.accent = DaddyPalette.mint.opacity(0.11)
        palette.border = DaddyPalette.mint.opacity(0.28)
        palette.hairline = DaddyPalette.mint.opacity(0.22)
        palette.success = DaddyPalette.mint
        palette.warning = DaddyPalette.amber
        palette.destructive = DaddyPalette.coral
        palette.displayWeight = 650
        palette.displayTracking = -0.02
        return palette
    }()
}

private struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        SMCard(padding: 0) { content }
    }
}

extension View {
    /// Keep the caller's spacing and its single scroll surface.
    func storagePanel() -> some View { modifier(Panel()) }
}
