import AppKit
import SwiftUI

/// Keep the semantic hue while providing contrast for small direct white labels.
enum MapTileFill {
    static func color(_ tint: Color, intensity: Double) -> Color {
        Color(nsColor: resolved(tint, intensity: intensity))
    }

    static func resolved(_ tint: Color, intensity: Double) -> NSColor {
        let source = NSColor(tint).usingColorSpace(.sRGB) ?? .black
        let depthScale = min(1, max(0, intensity / 0.9))
        let red = source.redComponent * 0.9
        let green = source.greenComponent * 0.9
        let blue = source.blueComponent * 0.9
        func luminance(_ scale: Double) -> Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red * scale) + 0.7152 * linear(green * scale) + 0.0722 * linear(blue * scale)
        }
        var scale = 1.0
        if luminance(scale) > 0.14 {
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let midpoint = (low + high) / 2
                if luminance(midpoint) <= 0.14 { low = midpoint } else { high = midpoint }
            }
            scale = low
        }
        // Opaque tiles prevent nested colors from accumulating over parent fills.
        // Intensity still makes children darker and filtered tiles quieter.
        return NSColor(srgbRed: red * scale * depthScale, green: green * scale * depthScale, blue: blue * scale * depthScale, alpha: 1)
    }
}
