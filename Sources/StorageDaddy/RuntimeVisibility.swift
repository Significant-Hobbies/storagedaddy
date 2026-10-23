import AppKit
import Combine
import SwiftUI

/// Native visibility, rather than key-window focus or scenePhase, controls the
/// process consumer. A visible inactive window can keep updating; a minimized,
/// hidden, fully occluded, or closed window releases its sampling consumer.
struct RuntimeVisibilityObserver: NSViewRepresentable {
    let model: RuntimeModel
    func makeNSView(context: Context) -> RuntimeVisibilityProbe {
        let view = RuntimeVisibilityProbe(); view.bind(model); return view
    }
    func updateNSView(_ view: RuntimeVisibilityProbe, context: Context) { view.bind(model) }
    static func dismantleNSView(_ view: RuntimeVisibilityProbe, coordinator: ()) { view.detach() }
}

@MainActor
final class RuntimeVisibilityProbe: NSView {
    private weak var model: RuntimeModel?
    private var observations = Set<AnyCancellable>()
    private weak var observedWindow: NSWindow?
    func bind(_ model: RuntimeModel) {
        if self.model !== model { self.model?.stopConsumer("processes"); self.model = model }
        if observedWindow !== window { attach() }
        updateVisibility()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach(); updateVisibility() }
    func detach() {
        observations.removeAll(); observedWindow = nil
        model?.stopConsumer("processes"); model = nil
    }
    private func attach() {
        observations.removeAll(); observedWindow = window
        guard let window else { model?.stopConsumer("processes"); return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateVisibility() }
            }.store(in: &observations)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.model?.stopConsumer("processes") }
        }.store(in: &observations)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.publisher(for: name, object: NSApplication.shared).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateVisibility() }
            }.store(in: &observations)
        }
    }
    private func updateVisibility() {
        if let window, window.isVisible, !window.isMiniaturized,
           window.occlusionState.contains(.visible), !NSApplication.shared.isHidden {
            model?.startConsumer("processes")
        } else { model?.stopConsumer("processes") }
    }
}
