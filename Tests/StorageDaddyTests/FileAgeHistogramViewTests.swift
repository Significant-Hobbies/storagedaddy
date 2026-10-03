import AppKit
import SwiftUI
import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

@Test @MainActor func ageHistogramOffscreenNativeFixtures() throws {
    let now = Date(timeIntervalSince1970: 1_754_006_400)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let files = (1...12).map { id in
        DiskNode(id: id, parent: 0, name: "synthetic", isDirectory: false, allocatedBytes: Int64(id * 1_000_000), modified: now.addingTimeInterval(-Double(id * 31) * 86400))
    }
    let scan = ScanResult(rootPath: "/synthetic-only", nodes: [DiskNode(id: 0, parent: nil, name: "fixture", isDirectory: true)] + files)
    let output = URL(fileURLWithPath: "/tmp/storagedaddy-age-evidence")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for width in [880, 1200, 1440] {
        let histogram = try FileAgeHistogram.calculate(in: scan, now: now, calendar: calendar)
        let view = FileAgeHistogramView(histogram: histogram, granularity: .monthly, onGranularityChange: { _ in }, onSelectNode: { _ in })
        let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: 600))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("age-\(width).png"))
        #expect(bitmap.pixelsWide >= width)
        #expect(bitmap.pixelsHigh >= 600)
        #expect(png.count > 10_000)
    }
}
