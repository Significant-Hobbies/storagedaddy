import AppKit
import DiskCore
import SwiftUI
import Testing
@testable import StorageDaddy

/// Opt-in native workload: the production CleanupView, 550 selected folders,
/// progress updates and repeated real scroll-view layouts. Never runs cleanup.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_CLEANUP_SCROLL_EVIDENCE"] == "1"))
func cleanupScrollWithLargeSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-scroll-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let count = 550
    var nodes = [DiskNode(id: 0, parent: nil, name: "Scroll workload", isDirectory: true)]
    var selected: Set<Int> = []
    for index in 0..<count {
        let projectID = nodes.count
        let folderID = projectID + 1
        let project = "project-\(index)"
        let isDependency = index.isMultiple(of: 10)
        nodes.append(DiskNode(id: projectID, parent: 0, name: project, isDirectory: true, children: [folderID]))
        nodes[0].children.append(projectID)
        nodes.append(DiskNode(id: folderID, parent: projectID, name: isDependency ? "node_modules" : "__pycache__",
                              isDirectory: true, allocatedBytes: 4096))
        selected.insert(folderID)
        if isDependency {
            let directory = root.appendingPathComponent(project)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("package.json"))
        }
    }
    let model = ExplorerModel()
    model.scan = ScanResult(rootPath: root.path, nodes: nodes)
    model.staged = selected
    model.quickCleanupCandidateIDs = selected.sorted()
    model.busy = true // matches the active-cleanup scene; actions stay disabled
    let host = NSHostingView(rootView: CleanupView().environmentObject(model)
        .storageTheme(DaddyTheme.palette, appearance: "dark"))
    let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 1100, height: 800),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.title = "StorageDaddy scrolling verification · synthetic folders"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    let scroll = try #require(scrollViews(host).first)
    let clock = ContinuousClock()
    var milliseconds: [Double] = []
    for step in 0..<24 {
        let start = clock.now
        model.progress = "Synthetic cleanup update \(step) · Nothing moved"
        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: step.isMultiple(of: 2) ? bottom : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let duration = start.duration(to: clock.now).components
        milliseconds.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        try await Task.sleep(for: .milliseconds(30))
    }
    var ordinaryScrollMilliseconds: [Double] = []
    for step in 0..<30 {
        let start = clock.now
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let duration = start.duration(to: clock.now).components
        ordinaryScrollMilliseconds.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.staged == selected, "Scrolling must not alter the reviewed selection")
    #expect(model.permanentCleanupIDs.count == 55)
    model.deleteNodeCachesPermanently = false
    host.layoutSubtreeIfNeeded()
    #expect(model.permanentCleanupIDs.isEmpty)
    #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentSize.height)
    let output = ProcessInfo.processInfo.environment["STORAGEDADDY_CLEANUP_SCROLL_OUTPUT"]
    if let output {
        let report: [String: Any] = ["selectedFolders": count, "windowWidth": 1100, "windowHeight": 800,
                                   "layoutMilliseconds": milliseconds, "ordinaryScrollMilliseconds": ordinaryScrollMilliseconds, "noCleanupInvoked": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
    if let ready = ProcessInfo.processInfo.environment["STORAGEDADDY_CLEANUP_SCROLL_READY"] {
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        try Data("ready".utf8).write(to: URL(fileURLWithPath: ready))
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: ready + ".done") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
