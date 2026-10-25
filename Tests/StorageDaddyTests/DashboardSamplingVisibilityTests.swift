import AppKit
import DiskCore
import Testing
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct DashboardSamplingVisibilityTests {
    @Test func unattachedDashboardDoesNotStartPeriodicSampling() async throws {
        let dashboard = DashboardModel()
        let samples = DashboardSampleCounter()
        let probe = DashboardSamplingProbe()
        probe.probe = { samples.next() }
        probe.interval = .milliseconds(5)
        probe.bind(dashboard)
        probe.bind(dashboard)
        try await Task.sleep(for: .milliseconds(30))
        #expect(samples.count == 0)
        #expect(dashboard.ioRates == .waiting)
        probe.detach()
        try await Task.sleep(for: .milliseconds(20))
        #expect(samples.count == 0)
    }

    @Test func explicitScanCompletesWithoutADashboardWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-sampling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 42, count: 4096).write(to: root.appendingPathComponent("fixture.bin"))
        let model = ExplorerModel()
        let samples = DashboardSampleCounter()
        let probe = DashboardSamplingProbe()
        probe.probe = { samples.next() }
        probe.interval = .milliseconds(5)
        probe.bind(model.dashboard)
        defer { probe.detach(); model.cancel() }

        model.start(root, allowProtectedFolder: true, notifyOnCompletion: false)
        for _ in 0..<500 {
            if !model.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.busy)
        let scan = try #require(model.scan)
        #expect(scan.nodes.contains { $0.name == "fixture.bin" && $0.logicalBytes == 4096 })
        #expect(samples.count == 0)
        #expect(model.dashboard.ioRates == .waiting)
    }
}

private final class DashboardSampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
    func next() -> StorageDashboardMetrics.IOSample {
        lock.lock(); defer { lock.unlock() }
        samples += 1
        return .init(uptime: Double(samples), bootTime: Date(timeIntervalSince1970: 100), drivers: [
            .init(registryID: 7, readBytes: UInt64(samples * 100), writtenBytes: UInt64(samples * 50))
        ])
    }
}
