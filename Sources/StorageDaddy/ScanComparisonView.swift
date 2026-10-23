import DiskCore
import SwiftUI

struct ScanComparisonView: View {
    @EnvironmentObject private var m: ExplorerModel
    let snapshot: SavedScanSnapshot
    @State private var beforeID: UUID?
    @State private var search = ""
    @State private var result: ScanFileDiff?
    @State private var error: String?
    @State private var loading = false
    @State private var page = 0

    private var candidates: [SavedScanSnapshot] {
        m.savedSnapshots.filter { $0.id != snapshot.id && $0.scan.rootPath == snapshot.scan.rootPath && $0.scan.started <= snapshot.scan.started }
    }
    private var identity: String { "\(snapshot.id):\(beforeID?.uuidString ?? ""):" + search }
    private let ranges: [(String, TimeInterval)] = [("1h", 3600), ("6h", 21600), ("1d", 86400), ("1w", 604800), ("1M", 2592000), ("3M", 7776000)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare file changes").font(.title3.weight(.semibold))
            if candidates.isEmpty {
                Text("Scan this folder again to compare its files. Scans now save a metadata-only index automatically unless disabled in Settings.")
                    .foregroundStyle(Tints.secondaryText)
            } else {
                Picker("Before", selection: $beforeID) {
                    Text("Choose a scan").tag(UUID?.none)
                    ForEach(candidates) { item in
                        Text(item.scan.started.formatted(date: .abbreviated, time: .standard)).tag(Optional(item.id))
                    }
                }
                HStack {
                    ForEach(ranges, id: \.0) { label, seconds in
                        Button(label) {
                            let target = snapshot.scan.started.addingTimeInterval(-seconds)
                            beforeID = candidates.filter { $0.scan.started <= target }.max(by: { $0.scan.started < $1.scan.started })?.id
                            if beforeID == nil { error = "No saved scan at least \(label) earlier for this folder."; result = nil }
                        }
                    }
                }
                TextField("Filter changed paths", text: $search).textFieldStyle(.roundedBorder)
                if loading { ProgressView("Comparing file metadata…").controlSize(.small) }
                if let error { Text(error).foregroundStyle(Tints.yellow).font(.callout) }
                if let result {
                    HStack {
                        Text("\(result.changeCount.formatted()) matching changes").font(.headline)
                        Spacer()
                        Text("Net logical \(signed(result.logicalDelta)) · attributed allocation \(signed(result.allocatedDelta))")
                            .font(.caption).monospacedDigit()
                    }
                    Text("Paths, sizes and modification dates only. A modified date is not proof that file contents changed. Renames appear as removed and added paths. Allocation changes can reflect hard-link or APFS ownership changes.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                    if result.partialCoverage {
                        Label("At least one scan was incomplete. Removed paths may have been skipped; totals describe observed entries only.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Tints.yellow)
                    }
                    if result.truncated {
                        Text("Showing the first 100,000 matches. Refine the path filter to inspect other changes. Net totals include every indexed entry.")
                            .font(.caption).foregroundStyle(Tints.yellow)
                    }
                    ForEach(Array(result.changes.dropFirst(page * 30).prefix(30))) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(change.kind.rawValue).font(.caption).foregroundStyle(change.kind == .removed ? Tints.coral : Tints.mint).frame(width: 66, alignment: .leading)
                            Text(change.path).font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Text(signed(change.logicalDelta)).font(.callout).monospacedDigit()
                        }.padding(.vertical, 4)
                    }
                    ListPagination(page: $page, total: result.changes.count, pageSize: 30, noun: "changes")
                }
            }
        }.padding(18).storagePanel()
            .task(id: identity) {
                result = nil; error = nil; page = 0
                guard let before = candidates.first(where: { $0.id == beforeID }) else { return }
                loading = true
                let directory = m.snapshotDirectory, query = search
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let worker = Task.detached(priority: .utility) {
                        try ScanFileIndex.compare(before: before, after: snapshot, directory: directory, search: query)
                    }
                    let comparison = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    result = comparison
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
                loading = false
            }
    }

    private func signed(_ value: Int64) -> String { (value > 0 ? "+" : "") + DiskFormat.bytes(value) }
}
