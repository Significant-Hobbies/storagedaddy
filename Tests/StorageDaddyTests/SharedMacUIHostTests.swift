import AppKit
import DiskCore
import SwiftUI
import Testing
@testable import StorageDaddy

/// Production shell on temporary files; interaction is separately opt-in and must not confirm cleanup.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_MAC_UI_EVIDENCE"] == "1"))
func sharedMacUIReviewHost() async throws {
    let environment = ProcessInfo.processInfo.environment
    let interactive = environment["STORAGEDADDY_MAC_UI_INTERACTION_EVIDENCE"] == "1"
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
    model.allocationIndex = StorageAllocationIndex(scan: scan)
    model.progress = "Temporary folder scan complete · Nothing moved"
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
        .environment(\.storageArtworkDirectory, URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets"))
        .allowsHitTesting(interactive).accessibilityHidden(!interactive))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "StorageDaddy UI review · temporary sample folders"
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = !interactive
    window.contentView = host
    NSApplication.shared.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    #expect(host.bounds.width > 0)
    try JSONSerialization.data(withJSONObject: ["windowNumber": window.windowNumber,
        "contentWidth": Double(host.bounds.width), "contentHeight": Double(host.bounds.height)])
        .write(to: URL(fileURLWithPath: ready))
    holdStorageReviewEventLoop(until: URL(fileURLWithPath: ready + ".done"))
    for folder in folders {
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).appendingPathComponent("sample.bin").path))
    }
}

@MainActor private func holdStorageReviewEventLoop(until done: URL) {
    let deadline = Date().addingTimeInterval(120)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard FileManager.default.fileExists(atPath: done.path) || Date() >= deadline else { return }
            NSApplication.shared.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApplication.shared.postEvent(event, atStart: false)
            }
        }
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSApplication.shared.run()
    timer.invalidate()
}
