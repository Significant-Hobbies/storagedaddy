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
