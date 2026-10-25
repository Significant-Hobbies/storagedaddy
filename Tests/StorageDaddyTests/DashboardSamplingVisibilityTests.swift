import AppKit
import DiskCore
import Testing
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct DashboardSamplingVisibilityTests {
    @Test func nativeWindowLifetimeControlsDashboardSampling() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let dashboard = DashboardModel()
        let samples = DashboardSampleCounter()
        let probe = DashboardSamplingProbe()
        probe.probe = { samples.next() }
        probe.interval = .milliseconds(10)
        probe.bind(dashboard)
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        let other = NSWindow(contentRect: NSRect(x: 760, y: 180, width: 240, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -30, dy: -30),
            styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = .floating
        defer {
            probe.detach()
            app.unhideWithoutActivation()
            cover.close()
            other.close()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(samples.count == 0)

        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await expectEventually { dashboard.ioRates.read == .measured(100) }
        other.makeKeyAndOrderFront(nil)
        let inactiveCount = samples.count
        try await expectEventually { samples.count > inactiveCount }

        window.miniaturize(nil)
        try await expectEventually { window.isMiniaturized }
        try await expectPaused(dashboard, samples)
        window.deminiaturize(nil)
        try await expectEventually { dashboard.ioRates.read == .measured(100) }

        window.orderOut(nil)
        try await expectPaused(dashboard, samples)
        #expect(other.isVisible)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-hidden-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 42, count: 4096).write(to: root.appendingPathComponent("fixture.bin"))
        let scan = try await DiskScanner.scan(root: root)
        #expect(scan.nodes.contains { $0.name == "fixture.bin" && $0.logicalBytes == 4096 })
        #expect(dashboard.ioRates == .waiting)
        window.orderFrontRegardless()
        try await expectEventually { dashboard.ioRates.read == .measured(100) }

        cover.orderFrontRegardless()
        try await expectEventually { !window.occlusionState.contains(.visible) }
        try await expectPaused(dashboard, samples)
        cover.orderOut(nil)
        try await expectEventually { dashboard.ioRates.read == .measured(100) }

        app.hide(nil)
        try await expectEventually { app.isHidden }
        try await expectPaused(dashboard, samples)
        app.unhide(nil)
        window.orderFrontRegardless()
        try await expectEventually { dashboard.ioRates.read == .measured(100) }

        window.close()
        try await expectPaused(dashboard, samples)
        window.makeKeyAndOrderFront(nil)
        try await expectEventually { dashboard.ioRates.read == .measured(100) }

        probe.removeFromSuperview()
        try await expectPaused(dashboard, samples)
        other.contentView = probe
        try await expectEventually { dashboard.ioRates.read == .measured(100) }
        probe.detach()
        try await expectPaused(dashboard, samples)
        print("Dashboard native visibility verified: visible inactive, minimized, ordered out with another window visible, occluded, app hidden, closed, reopened, reattached, dismantled")
    }

    private func expectPaused(_ dashboard: DashboardModel, _ samples: DashboardSampleCounter) async throws {
        try await expectEventually { dashboard.ioRates == .waiting }
        let count = samples.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(samples.count == count)
    }

    private func expectEventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
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
