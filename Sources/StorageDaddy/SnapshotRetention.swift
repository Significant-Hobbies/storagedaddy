import DiskCore
import Foundation

extension ExplorerModel {
    func applySnapshotRetention() async {
        let count = UserDefaults.standard.integer(forKey: "snapshotRetentionPerRoot")
        guard (7...30).contains(count), !busy, !moves.busy else { return }
        let directory = snapshotDirectory
        let wasSaving = snapshotBusy
        snapshotBusy = true
        defer { snapshotBusy = wasSaving }
        do {
            try await Task.detached(priority: .utility) {
                let listing = try SnapshotHistoryStore.load(directory: directory)
                for snapshot in SnapshotHistoryStore.excessSnapshots(listing.snapshots, retainingPerRoot: count) {
                    try Task.checkCancellation()
                    try SnapshotHistoryStore.trash(id: snapshot.id, directory: directory)
                }
            }.value
            await refreshSnapshotHistory()
        } catch {
            await refreshSnapshotHistory()
            snapshotHistoryWarning = "Older history could not all be moved to Trash. " + error.localizedDescription
        }
    }
}
