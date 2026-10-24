import AppKit
import SwiftUI
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct DiskHoundParityRenderingTests {
    @Test func nativeParityViewsRenderAtSupportedWindowWidths() async throws {
        let model = ExplorerModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/node_modules"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("project/package.json"))
        try Data(repeating: 1, count: 65_536).write(to: root.appendingPathComponent("project/node_modules/module.js"))
        try Data(repeating: 1, count: 65_536).write(to: root.appendingPathComponent("project/node_modules/module-copy.js"))
        let scan = try await DiskScanner.scan(root: root)
        let duplicates = try await DuplicateFinder.find(in: scan)
        model.scan = scan; model.developerGroups = DeveloperInsights.analyze(scan)
        model.developerReport = DeveloperReport.build(scan: scan, groups: model.developerGroups)
        model.mapIndex = StorageMapIndex(scan: scan, groups: model.developerGroups)
        model.focus = 0; model.mode = .treemap
        await model.runtime.refresh()
        try await Task.sleep(for: .milliseconds(150))
        await model.runtime.refresh()
        await model.runtime.refreshDrives()
        let monitoringWasEnabled = model.runtime.monitoringEnabled
        for width in [880, 1100, 1440] {
            model.workspace = .processes
            model.runtime.presentation = .list
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "process-list-\(width)", width: width)
            model.runtime.presentation = .memoryMap
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "memory-map-\(width)", width: width)
            model.runtime.presentation = .cpuHeatmap
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "cpu-heatmap-\(width)", width: width)
            if width == 880 {
                try capture(AnyView(RuntimeView(model: model.runtime)), name: "process-light-880", width: 880, appearance: "light")
            }
            model.runtime.presentation = .list; model.runtime.grouping = .application
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "process-app-groups-\(width)", width: width)
            model.runtime.grouping = .individual
            if let process = model.runtime.snapshot?.processes.first {
                model.runtime.selectedID = process.id; model.runtime.presentation = .details
                try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "process-details-\(width)", width: width)
            }
            try capture(AnyView(DuplicateReviewView(scan: scan, groups: duplicates, isLoading: false, error: nil, onFind: {}, onCancel: {}, onStage: { _ in }, hasSearched: true)), name: "duplicate-review-\(width)", width: width)
            try capture(AnyView(GitWorktreeView().environmentObject(model)), name: "git-worktrees-\(width)", width: width)
            try capture(AnyView(PackageCacheCleanersView().environmentObject(model)), name: "native-cache-cleaners-\(width)", width: width)
            try capture(AnyView(SavedHistoryView().environmentObject(model)), name: "saved-history-\(width)", width: width)
            try capture(AnyView(DriveMonitoringView(model: model.runtime)), name: "drive-monitoring-\(width)", width: width)
            try capture(AnyView(AgentAccessView(agents: model.agentAccess)), name: "agent-access-off-\(width)", width: width)
            try capture(AnyView(ScanScheduleSettingsView(schedule: model.scanSchedule)), name: "scan-schedule-\(width)", width: width)
            try capture(AnyView(EasyMoveView(model: model.moves)), name: "easy-move-history-\(width)", width: width)
        }
        #expect(!model.agentAccess.enabled)
        #expect(model.runtime.monitoringEnabled == monitoringWasEnabled)
        #expect(model.staged.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/node_modules/module.js").path))
    }

    private func capture(_ view: AnyView, name: String, width: Int, appearance: String = "dark") throws {
        let host = NSHostingView(rootView: view.storageTheme(DaddyTheme.palette, appearance: appearance)
            .frame(width: CGFloat(width), height: 850).background(AppColors.canvas))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/diskhound-parity")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        #expect(host.bounds.width == CGFloat(width))
        #expect(host.bounds.height == 850)
    }
}
