import AppKit
import Foundation

/// A packaging-only check of the real SwiftUI window, not an alternate UI.
@MainActor enum StorageStartupCheck {
    static let enabled = CommandLine.arguments.contains("--check-app-startup")
    private static var started = false

    static func windowAppeared(model: ExplorerModel) {
        guard enabled, !started else { return }
        started = true
        Task { @MainActor in
            // Let launch actions, layout and the synthetic scan finish.
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<100 {
                if !model.isScanning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let expectsScan = CommandLine.arguments.contains("--scan")
            guard !model.isScanning, !expectsScan || model.scan != nil,
                  let window = NSApplication.shared.windows.first(where: {
                      $0.isVisible && $0.contentView != nil && $0.title == "storagedaddy"
                  }) else { exit(EXIT_FAILURE) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            FileHandle.standardOutput.write(Data("StorageDaddy app startup verified\n".utf8))
            exit(EXIT_SUCCESS)
        }
    }
}
