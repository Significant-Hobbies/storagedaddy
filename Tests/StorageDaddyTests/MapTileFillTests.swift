import AppKit
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor struct MapTileFillTests {
    @Test func directLabelsHaveContrastAcrossEverySemanticAndReviewState() {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        for tint in StorageKind.allCases.map(Tints.forKind) + [Tints.coral] {
            let parent = MapTileFill.resolved(tint, intensity: 0.9)
            let child = MapTileFill.resolved(tint, intensity: 0.65)
            let filtered = MapTileFill.resolved(tint, intensity: 0.18)
            for fill in [parent, child] {
                #expect(1.05 / (luminance(fill) + 0.05) >= 5.5)
                #expect(fill.alphaComponent == 1)
            }
            #expect((luminance(NSColor(white: 0.78, alpha: 1)) + 0.05) / (luminance(filtered) + 0.05) >= 4.5)
            #expect(luminance(child) <= luminance(parent))
            #expect(luminance(filtered) < luminance(child))
        }
    }
}
