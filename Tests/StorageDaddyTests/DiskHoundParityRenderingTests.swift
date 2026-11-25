import AppKit
import SwiftUI
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct DiskHoundParityRenderingTests {
    @Test(.timeLimit(.minutes(2)))
    func twoClickTargetDeletesOnlyReviewedStartupDiskDependencies() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("space-target-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let projects = home.appendingPathComponent("Projects")
        try fm.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        for (name, size) in [("Larger", 65536), ("Smaller", 4096)] {
            let project = projects.appendingPathComponent(name)
            let dependencies = project.appendingPathComponent("node_modules")
            try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
            try Data(repeating: 42, count: size).write(to: dependencies.appendingPathComponent("index.js"))
        }
        let buildFiles = [
            "Website/package.json", "Website/.next/build-manifest.json", "Website/.next/cache/webpack/entry",
            "Website/.next/server/app.js", "Native/Package.swift", "Native/.build/workspace-state.json",
            "Native/.build/out/Intermediates.noindex/compiled.o", "Native/.build/checkouts/Library/source.swift",
            "Unverified/package.json", "Unverified/.next/cache/personal-file"
        ]
        for path in buildFiles {
            let file = projects.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: 8192).write(to: file)
        }
        let npx = home.resolvingSymlinksInPath().appendingPathComponent(".npm/_npx/1234567890abcdef")
        let cachedPackage = npx.appendingPathComponent("node_modules/sd-unused-fixture")
        try fm.createDirectory(at: cachedPackage, withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"sd-unused-fixture":"1.0.0"}}"#.utf8).write(to: npx.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: cachedPackage.appendingPathComponent("package.json"))
        let model = ExplorerModel(developerCleanupPreferences: nil)
        let target = try #require(StartupCapacity(total: 100_001, available: 50_000))
        #expect(target.usedPercent == 50)
        model.openSpaceTarget(target, home: home.resolvingSymlinksInPath())
        await model.waitForCurrentStorageOperation()
        let plan = try #require(model.developerCleanupPlan)
        #expect(model.showsDeveloperCleanupReview)
        #expect(model.developerCleanupFolders.isEmpty)
        #expect(plan.scopes.count == 2)
        #expect(plan.items.count == 5)
        #expect(plan.reclaimable(on: nil).items.isEmpty)
        let item = try #require(plan.items.first)
        #expect(item.path.contains("/Larger/"))
        #expect(model.developerCleanupSelectedIDs == Set(plan.items.map(\.id)))
        if ProcessInfo.processInfo.environment["STORAGEDADDY_DEVELOPER_CLEANUP_EVIDENCE"] == "1" {
            for width in [880, 1100, 1440] {
                try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)),
                            name: "space-target-\(width)", width: width)
            }
        }
        model.confirmDeveloperCleanup(planID: plan.id, ids: model.developerCleanupSelectedIDs, permanently: true)
        await model.waitForCurrentStorageOperation()
        #expect(model.developerCleanupOutcome?.deleted == Set(plan.items.map(\.id)))
        #expect(!fm.fileExists(atPath: cachedPackage.path))
        #expect(fm.fileExists(atPath: npx.appendingPathComponent("package.json").path))
        #expect(!fm.fileExists(atPath: item.path))
        for path in buildFiles {
            let cleaned = path.hasSuffix("/entry") || path.hasSuffix("/compiled.o")
            #expect(fm.fileExists(atPath: projects.appendingPathComponent(path).path) == !cleaned)
        }
        #expect(fm.fileExists(atPath: projects.appendingPathComponent("Larger/package.json").path))
        #expect(!fm.fileExists(atPath: projects.appendingPathComponent("Smaller/node_modules/index.js").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_DEVELOPER_CLEANUP_EVIDENCE"] == "1"),
          .timeLimit(.minutes(2)))
    func developerCleanupShowsOneReviewAndConfirmsSelectedFolders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Developer Cleanup Demo \(UUID())")
        defer { try? fm.removeItem(at: root) }

        let projects = root.appendingPathComponent("Projects")
        let worktrees = root.appendingPathComponent("Linked Worktrees")
        let web = projects.appendingPathComponent("build/Website")
        let dependencies = web.appendingPathComponent("node_modules")
        let manifest = web.appendingPathComponent("package.json")
        try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projects.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: manifest)
        try Data(repeating: 1, count: 2_097_152).write(to: dependencies.appendingPathComponent("module.js"))
        let native = worktrees.appendingPathComponent("NativeLibrary")
        let build = native.appendingPathComponent(".build")
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: native.appendingPathComponent("Package.swift"))
        try Data(repeating: 1, count: 1_048_576).write(to: build.appendingPathComponent("object.o"))

        let model = ExplorerModel(developerCleanupPreferences: nil)
        model.workspace = .cleanup
        model.showingDeveloperCleanup = true
        #expect(model.showsDeveloperCleanupReview)
        model.staged = [1]
        #expect(!model.showsDeveloperCleanupReview)
        model.openQuickCleanup()
        model.staged = []
        #expect(!model.showsDeveloperCleanupReview)
        model.showingDeveloperCleanup = true
        model.findDeveloperCleanup(in: [projects, worktrees])
        await model.waitForCurrentStorageOperation()
        try Task.checkCancellation()
        let plan = try #require(model.developerCleanupPlan)
        #expect(model.scan == nil)
        #expect(plan.items.count == 4)
        #expect(Set(plan.items.map(\.id.scope)).count == 2)
        model.findDeveloperCleanup(in: [projects, worktrees, web], retainingReviewOnFailure: true)
        await model.waitForCurrentStorageOperation()
        try Task.checkCancellation()
        #expect(model.developerCleanupPlan?.id == plan.id)
        #expect(model.developerCleanupError?.contains("overlaps") == true)
        model.setDeveloperCleanupDeletesPermanently(false, planID: plan.id)
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets")
        let invalidScope = ExplorerModel(developerCleanupPreferences: nil)
        invalidScope.workspace = .cleanup
        invalidScope.showingDeveloperCleanup = true
        invalidScope.findDeveloperCleanup(in: [dependencies])
        await invalidScope.waitForCurrentStorageOperation()
        try Task.checkCancellation()
        let invalidPlan = try #require(invalidScope.developerCleanupPlan)
        #expect(invalidPlan.items.isEmpty)
        #expect(invalidPlan.scopes.first?.error?.contains("project folder") == true)
        for width in [880, 1100, 1440] {
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(model)
                .environment(\.storageArtworkDirectory, assets)), name: "developer-cleanup-\(width)", width: width)
            try capture(AnyView(ExplorerView(runsLaunchActions: false).environmentObject(invalidScope)
                .environment(\.storageArtworkDirectory, assets)), name: "developer-cleanup-invalid-scope-\(width)", width: width)
        }
        let permanentItem = plan.items.first { $0.canDeletePermanently }
        let item = try #require(permanentItem)
        model.confirmDeveloperCleanup(planID: UUID(), ids: [item.id], permanently: false)
        #expect(!model.busy)
        #expect(fm.fileExists(atPath: dependencies.path))
        model.setDeveloperCleanupDeletesPermanently(true, planID: plan.id)
        model.confirmDeveloperCleanup(planID: plan.id, ids: [item.id], permanently: true)
        #expect(model.developerCleanupError == nil)
        await model.waitForCurrentStorageOperation()
        try Task.checkCancellation()
        #expect(model.developerCleanupOutcome?.deleted == Set(plan.items.map(\.id)))
        #expect(!fm.fileExists(atPath: dependencies.path))
        #expect(fm.fileExists(atPath: manifest.path))
        #expect(fm.fileExists(atPath: build.path))
        model.openQuickCleanup()
        model.openDeveloperCleanup()
        #expect(model.developerCleanupOutcome?.deleted == Set(plan.items.map(\.id)))
        #expect(!model.busy)
        model.finishViewingDeveloperCleanupResult()
        #expect(model.developerCleanupOutcome == nil)
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
