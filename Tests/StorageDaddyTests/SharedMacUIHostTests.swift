import AppKit
import DiskCore
import SwiftUI
import Testing
@testable import StorageDaddy

/// Capture-only production shell on temporary files. Drivers must only take screenshots.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_MAC_UI_EVIDENCE"] == "1"))
func sharedMacUIReviewHost() async throws {
    let environment = ProcessInfo.processInfo.environment
    let ready = try #require(environment["STORAGEDADDY_MAC_UI_READY"])
    let defaults = UserDefaults.standard
    let priorArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var fixtureArguments = priorArguments
    fixtureArguments["cleanupRefreshPaths"] = [String]()
    defaults.setVolatileDomain(fixtureArguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(priorArguments, forName: UserDefaults.argumentDomain) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-ui-review-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folders = ["website/node_modules", "tools/__pycache__"]
    for folder in folders {
        let location = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 4096).write(to: location.appendingPathComponent("sample.bin"))
    }
    try Data("{}".utf8).write(to: root.appendingPathComponent("website/package.json"))
    let scan = try await DiskScanner.scan(root: root)
    let ids = scan.nodes.filter { ["node_modules", "__pycache__"].contains($0.name) }.map(\.id)
    #expect(ids.count == 2)
    let model = ExplorerModel()
    model.scan = scan
    model.developerGroups = DeveloperInsights.analyze(scan)
    model.developerReport = DeveloperReport.build(scan: scan, groups: model.developerGroups)
    model.quickCleanupCandidateIDs = ids
    model.staged = Set(ids)
    model.openStorage(.cleanup)
    let width = Double(environment["STORAGEDADDY_MAC_UI_WIDTH"] ?? "") ?? 1200
    let height = Double(environment["STORAGEDADDY_MAC_UI_HEIGHT"] ?? "") ?? 850
    try #require((320...2400).contains(width) && (320...1800).contains(height))
    let host = NSHostingView(rootView: ExplorerView(runsLaunchActions: false)
        .environmentObject(model).storageTheme(DaddyTheme.palette, appearance: "dark")
        .allowsHitTesting(false).accessibilityHidden(true))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "StorageDaddy UI review · temporary sample folders"
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.contentView = host
    NSApplication.shared.setActivationPolicy(.regular)
    window.orderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    #expect(host.bounds.width > 0)
    try Data("ready".utf8).write(to: URL(fileURLWithPath: ready))
    for _ in 0..<1_200 {
        if FileManager.default.fileExists(atPath: ready + ".done") { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    for folder in folders {
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).appendingPathComponent("sample.bin").path))
    }
}
