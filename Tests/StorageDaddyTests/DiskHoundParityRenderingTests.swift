import AppKit
import SwiftUI
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct DiskHoundParityRenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_DEVELOPER_CLEANUP_EVIDENCE"] == "1"))
    func developerCleanupShowsOneReviewAndConfirmsSelectedFolders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Developer Cleanup Demo \(UUID())")
        defer { try? fm.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "developerCleanupFolder")
        defer { defaults.set(previous, forKey: "developerCleanupFolder") }

        let web = root.appendingPathComponent("Website")
        let dependencies = web.appendingPathComponent("node_modules")
        let manifest = web.appendingPathComponent("package.json")
        try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest)
        try Data(repeating: 1, count: 2_097_152).write(to: dependencies.appendingPathComponent("module.js"))
        let native = root.appendingPathComponent("NativeLibrary")
        let build = native.appendingPathComponent(".build")
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: native.appendingPathComponent("Package.swift"))
        try Data(repeating: 1, count: 1_048_576).write(to: build.appendingPathComponent("object.o"))

        let model = ExplorerModel()
        model.workspace = .cleanup
        model.showingDeveloperCleanup = true
        model.findDeveloperCleanup(in: root)
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let plan = try #require(model.developerCleanupPlan)
        #expect(model.scan == nil)
        #expect(plan.items.count == 2)
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets")
        for width in [880, 1100, 1440] {
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)
                .environment(\.storageArtworkDirectory, assets)), name: "developer-cleanup-\(width)", width: width)
        }
        let permanentItem = plan.items.first { $0.canDeletePermanently }
        let item = try #require(permanentItem)
        model.confirmDeveloperCleanup(planID: UUID(), ids: [item.id], permanently: true)
        #expect(!model.busy)
        #expect(fm.fileExists(atPath: dependencies.path))
        model.confirmDeveloperCleanup(planID: plan.id, ids: [item.id], permanently: true)
        let removalDeadline = Date().addingTimeInterval(10)
        while model.busy && Date() < removalDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.developerCleanupOutcome?.deleted == [item.id])
        #expect(!fm.fileExists(atPath: dependencies.path))
        #expect(fm.fileExists(atPath: manifest.path))
        #expect(fm.fileExists(atPath: build.path))
    }

    @Test func cleanupRefreshFollowsTheActiveScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = try await DiskScanner.scan(root: root)

        let defaults = UserDefaults.standard
        let priorArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = priorArguments
        arguments["cleanupRefreshPaths"] = [root.appendingPathComponent("removed-test-folder").path, scan.rootPath]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(priorArguments, forName: UserDefaults.argumentDomain) }

        let model = ExplorerModel()
        model.workspace = .cleanup
        #expect(model.cleanupRefreshPath == nil)
        model.scan = scan
        #expect(model.cleanupRefreshPath == scan.rootPath)
        model.scanIsHistorical = true
        #expect(model.cleanupRefreshPath == nil)
        model.scanIsHistorical = false
        model.workspace = .dashboard
        #expect(model.cleanupRefreshPath == nil)

        if ProcessInfo.processInfo.environment["STORAGEDADDY_OVERVIEW_EVIDENCE"] == "1" {
            model.dashboard.report = SystemInventory.collect()
            for width in [880, 1100, 1440] {
                model.workspace = .dashboard
                try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "cleanup-overview-\(width)", width: width)
                model.workspace = .cleanup
                try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)), name: "cleanup-refresh-\(width)", width: width)
            }
        }
    }

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
