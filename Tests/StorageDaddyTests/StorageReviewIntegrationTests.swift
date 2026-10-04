import AppKit
import SwiftUI
import Testing
@testable import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct StorageReviewIntegrationTests {
    private func volume() -> MountedVolumeInfo {
        MountedVolumeInfo(name: "Fixture Data", mountPoint: "/System/Volumes/Data", fsType: "apfs", bsdName: "disk99s5",
            totalCapacity: 500_000_000_000, availableCapacity: 100_000_000_000, importantAvailableCapacity: 130_000_000_000,
            isStartupData: true, isSystem: false, isInternal: true, isRemovable: false, isEjectable: false,
            isReadOnly: false, isNetwork: false, isEncrypted: true, isDiskImage: false, apfsContainer: "disk99",
            inodeTotal: nil, inodeFree: nil)
    }
    @Test func scoreDoesNotAssignRootSnapshotsOrDriveWearToSynthesizedDataVolume() {
        var pressure = PressureInfo(); pressure.localSnapshotNames = ["fixture-snapshot"]
        let report = SystemStorageReport(collectedAt: Date(), volumes: [volume()], containers: [], devices: [], pressure: pressure)
        let (_, score) = DashboardModel.scopedScore(report)
        #expect(score.measuredCount == 2)
        #expect(score.components.first { $0.id == "Local snapshots" }?.points == nil)
        #expect(score.components.first { $0.id == "NVMe wear" }?.points == nil)
        #expect(!score.isComplete)
    }
    @Test func visibleSamplerStopsAndResetsAfterCancellation() async throws {
        let sampler = FixtureSampler(); let dashboard = DashboardModel()
        let task = Task { await dashboard.sampleWhileVisible(probe: { sampler.next() }, interval: .milliseconds(5)) }
        for _ in 0..<100 {
            if case .measured = dashboard.ioRates.read { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(dashboard.ioRates.read == .measured(100))
        task.cancel(); await task.value
        #expect(dashboard.ioRates == .waiting)
        let count = sampler.count
        try await Task.sleep(for: .milliseconds(20))
        #expect(sampler.count == count)
    }
    @Test func projectsAppDataAndMetricsRenderEveryStateWithoutActions() throws {
        let old = Date().addingTimeInterval(-30 * 86400)
        let scan = ScanResult(rootPath: "/tmp/storage-project-review-fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "Fixture workspace", isDirectory: true, modified: old, children: [1, 2]),
            DiskNode(id: 1, parent: 0, name: "package.json", isDirectory: false, modified: old),
            DiskNode(id: 2, parent: 0, name: "node_modules", isDirectory: true, allocatedBytes: 180_000_000, modified: old, children: [3]),
            DiskNode(id: 3, parent: 2, name: "index.js", isDirectory: false, allocatedBytes: 180_000_000, modified: old)
        ])
        let report = DeveloperReport.build(scan: scan, groups: DeveloperInsights.analyze(scan))
        let records = ProjectPurgeReview.build(scan: scan, report: report, probes: [0: ProjectPurgeProbe(
            git: .verified(trackedNodeIDs: [], checkoutRootIDs: [0]), recoveryPlans: [2: "Restore dependencies from the reviewed manifest and lockfile."])])
        #expect(records.first?.stageableArtifactIDs == [2])
        let library = URL(fileURLWithPath: "/tmp/storage-app-data-fixture/Library")
        let dataScan = ScanResult(rootPath: library.path, nodes: [
            DiskNode(id: 0, parent: nil, name: "Library", isDirectory: true, children: [1]),
            DiskNode(id: 1, parent: 0, name: "Caches", isDirectory: true, children: [2, 3]),
            DiskNode(id: 2, parent: 1, name: "com.fixture.live", isDirectory: true, allocatedBytes: 12_000_000),
            DiskNode(id: 3, parent: 1, name: "org.example.retired", isDirectory: true, allocatedBytes: 90_000_000)
        ])
        let reference = AppLeftoverInventory(applications: [.init(bundleID: "com.fixture.live", names: ["Live"])], completeness: .complete, checkedAt: old)
        let appData = AppLeftoverReview.analyze(scan: dataScan, inventory: reference, libraryRoot: library)
        let partial = AppLeftoverReview.analyze(scan: dataScan, inventory: .init(applications: [], completeness: .partial, checkedAt: nil), libraryRoot: library)
        let score = StorageDashboardMetrics.score(totalBytes: volume().totalCapacity, freeBytes: volume().availableCapacity,
            purgeableBytes: 30_000_000_000, nvmePercentUsed: nil, snapshotCount: nil)
        var actions = 0
        for width in [880, 1200, 1440] {
            let views: [(String, AnyView)] = [
                ("projects-ready", AnyView(ProjectPurgeView(records: records, scan: scan, status: .ready, initialFocusedProjectID: 0,
                    onRecoveryPlan: { _, _ in actions += 1 }, onStageArtifactIDs: { _ in actions += 1 }))),
                ("projects-loading", AnyView(ProjectPurgeView(records: [], scan: scan, status: .loading, onStageArtifactIDs: { _ in actions += 1 }))),
                ("projects-error", AnyView(ProjectPurgeView(records: [], scan: scan, status: .error("Git index unavailable. Refresh project evidence."), onRetry: { actions += 1 }, onStageArtifactIDs: { _ in actions += 1 }))),
                ("projects-empty", AnyView(ProjectPurgeView(records: [], scan: scan, status: .ready, onStageArtifactIDs: { _ in actions += 1 }))),
                ("app-data-candidate", AnyView(AppLeftoverReviewView(result: appData, reviewEnabled: true,
                    initialInspectedPath: library.appendingPathComponent("Caches/org.example.retired").path,
                    onInspect: { _ in actions += 1 }, onReview: { _ in actions += 1 }))),
                ("app-data-partial", AnyView(AppLeftoverReviewView(result: partial, reviewEnabled: false,
                    onInspect: { _ in actions += 1 }, onReview: { _ in actions += 1 }))),
                ("metrics-waiting", AnyView(StorageDashboardMetricsView(volumes: [volume()], rates: .waiting, score: score,
                    scoreScope: "Fixture startup capacity", isRefreshing: false, onRefresh: { actions += 1 }, onReviewSnapshots: { actions += 1 })))
            ]
            for (name, view) in views { try capture(view, name: "\(name)-\(width)", width: width) }
        }
        #expect(actions == 0)
    }
    private func capture(_ view: AnyView, name: String, width: Int) throws {
        let root = view.padding(20).frame(width: CGFloat(width), height: 1000, alignment: .topLeading)
            .background(Color.black).preferredColorScheme(.dark).tint(Tints.mint).buttonStyle(StorageButtonStyle())
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false); window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        #expect(host.bounds.width == CGFloat(width))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/review-integration")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

private final class FixtureSampler: @unchecked Sendable {
    private let lock = NSLock(); private var samples = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
    func next() -> StorageDashboardMetrics.IOSample {
        lock.lock(); defer { lock.unlock() }; samples += 1
        return .init(uptime: Double(samples), bootTime: Date(timeIntervalSince1970: 100), drivers: [
            .init(registryID: 7, readBytes: UInt64(samples * 100), writtenBytes: UInt64(samples * 50))
        ])
    }
}
