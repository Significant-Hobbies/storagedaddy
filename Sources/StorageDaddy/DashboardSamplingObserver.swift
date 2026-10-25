import AppKit
import Combine
import DiskCore
import SwiftUI

struct DashboardSamplingObserver: NSViewRepresentable {
    let dashboard: DashboardModel

    func makeNSView(context: Context) -> DashboardSamplingProbe {
        let view = DashboardSamplingProbe()
        view.bind(dashboard)
        return view
    }

    func updateNSView(_ view: DashboardSamplingProbe, context: Context) { view.bind(dashboard) }
    static func dismantleNSView(_ view: DashboardSamplingProbe, coordinator: ()) { view.detach() }
}

@MainActor
final class DashboardSamplingProbe: NSView {
    var probe: @Sendable () -> StorageDashboardMetrics.IOSample = StorageDashboardMetrics.collectIOSample
    var interval: Duration = .seconds(2)
    private weak var dashboard: DashboardModel?
    private weak var observedWindow: NSWindow?
    private var observations = Set<AnyCancellable>()
    private var samplingTask: Task<Void, Never>?

    func bind(_ dashboard: DashboardModel) {
        if self.dashboard !== dashboard {
            stopSampling()
            self.dashboard = dashboard
        }
        if observedWindow !== window { attach() }
        updateSampling()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
        updateSampling()
    }

    func detach() {
        stopSampling()
        observations.removeAll()
        observedWindow = nil
        dashboard = nil
    }

    private func attach() {
        stopSampling()
        observations.removeAll()
        observedWindow = window
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateSampling() }
            }.store(in: &observations)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window).sink { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.observedWindow === window else { return }
                self.stopSampling()
            }
        }.store(in: &observations)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.publisher(for: name, object: NSApplication.shared).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateSampling() }
            }.store(in: &observations)
        }
    }

    private func updateSampling() {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !NSApplication.shared.isHidden else {
            stopSampling()
            return
        }
        guard samplingTask == nil, let dashboard else { return }
        let probe = probe, interval = interval
        samplingTask = Task { await dashboard.sampleWhileVisible(probe: probe, interval: interval) }
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }
}
