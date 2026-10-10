import Combine

@MainActor final class AppUpdates: DaddyAppUpdates {
    init() { super.init(appName: "StorageDaddy", busyMessage: "Finish the current scan, export or cleanup review before checking for updates.") }

    func start(model: ExplorerModel) {
        start(observing: model.objectWillChange.merge(with: model.conversationArchive.objectWillChange).eraseToAnyPublisher()) { [weak model] in
            guard let model else { return false }
            return model.macTools?.allowsUpdateInstallation != false && !model.busy && !model.monitoring && model.staged.isEmpty && !model.conversationArchive.busy && !model.snapshotBusy && !model.showCleanup
        }
    }
}
