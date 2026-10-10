import AppKit
import SwiftUI
import SaaSMakerUI
import XCTest
@testable import MacTools

final class MacToolsRenderingTests: XCTestCase {
    @MainActor func testPagesRenderAtSupportedWidths() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/design/mac-controls")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pages: [(String, Page)] = [("overview", .overview), ("intelligence", .intelligence),
            ("background", .background), ("storage", .storage), ("undo", .changes)]
            + TweakGroup.allCases.map { ($0.rawValue, .group($0)) }
        for width in [680, 1000, 1240] {
            for (name, page) in pages {
                let model = AppModel(loadSystem: false)
                model.page = page
                model.loadingModels = false
                model.states = Dictionary(uniqueKeysWithValues: Tweaks.all.map { ($0.id, .notApplied) })
                model.featureStates = Dictionary(uniqueKeysWithValues: Catalog.features.map { ($0.id, .on) })
                model.modelBytes = [Catalog.foundationModels: 6_000_000_000, Catalog.visualModels: 2_000_000_000]
                let view = StorageDaddyMacToolsView(session: MacToolsSession(model: model),
                    accent: Color(red: 0.60, green: 0.84, blue: 0.51), secondaryInk: Color(white: 0.65))
                    .smTheme(.ink)
                    .preferredColorScheme(.dark)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 820)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1_000)
                try png.write(to: output.appendingPathComponent("\(name)-\(width).png"))
            }
        }
    }
}
