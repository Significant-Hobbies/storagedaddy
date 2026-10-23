import SwiftUI
import SaaSMakerUI
import AppKit

enum AppColors {
    static let canvas = adaptive(dark: .black, light: NSColor(white: 0.98, alpha: 1))
    static let ink = adaptive(dark: .white, light: NSColor(white: 0.08, alpha: 1))
    static let secondary = adaptive(dark: NSColor(red: 0.78, green: 0.90, blue: 0.86, alpha: 1), light: NSColor(white: 0.34, alpha: 1))
    static let mint = adaptive(dark: NSColor(red: 0.42, green: 0.79, blue: 0.62, alpha: 1), light: NSColor(red: 0.08, green: 0.40, blue: 0.27, alpha: 1))
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private struct StorageAppearance: ViewModifier {
    @AppStorage("appearanceMode") private var appearance = "dark"
    var override: String?
    func body(content: Content) -> some View {
        let choice = override ?? appearance
        content.preferredColorScheme(choice == "system" ? nil : choice == "light" ? .light : .dark)
    }
}

/// Fleet typography and components with the Daddy-series canvas and evidence colors.
enum DaddyTheme {
    static let palette: SMPalette = {
        var palette = SMPalette.ink.brand(
            Color(red: 107 / 255, green: 201 / 255, blue: 158 / 255), foreground: .black
        )
        palette.background = AppColors.canvas
        palette.surface = AppColors.canvas
        palette.card = AppColors.canvas
        palette.foreground = AppColors.ink
        palette.primary = AppColors.ink
        palette.primaryForeground = AppColors.canvas
        palette.brand = AppColors.mint
        palette.brandForeground = AppColors.canvas
        palette.mutedForeground = AppColors.secondary
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
    /// Apply the shared palette without its fatal SwiftPM resource accessor.
    func storageTheme(_ palette: SMPalette, appearance: String? = nil) -> some View {
        _ = StorageUIResources.loaded
        return environment(\.smPalette, palette)
            .tint(palette.brand)
            .foregroundStyle(palette.foreground)
            .font(.custom(palette.sansFont, size: 16, relativeTo: .body))
            .background(palette.background.ignoresSafeArea())
            .modifier(StorageAppearance(override: appearance))
    }

    /// Keep the caller's spacing and its single scroll surface.
    func storagePanel() -> some View { modifier(Panel()) }
}
