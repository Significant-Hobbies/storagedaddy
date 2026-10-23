import SwiftUI
import SaaSMakerUI
import DiskCore
import AppKit

struct SavedHistoryView: View {
    @EnvironmentObject private var m: ExplorerModel
    @AppStorage("snapshotRetentionPerRoot") private var retentionCount = 0
    @State private var proposedRetention: Int?
    @State private var retentionBusy = false
    @State private var selected: UUID?
    @State private var page = 0
    @State private var trashReview: SavedScanSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        SMSectionHeader("History", size: 28).accessibilityLabel("History")
                        Text("Local scan history and changes over time.").foregroundStyle(Tints.secondaryText)
                    }
                    DoodleArt(topic: .snapshots).frame(width: 80, height: 80)
                    Spacer()
                    if !m.savedSnapshots.isEmpty {
                        Button("refresh", systemImage: "arrow.clockwise") { Task { await m.refreshSnapshotHistory() } }.accessibilityLabel("Refresh")
                            .disabled(m.snapshotHistoryLoading)
                    }
                }
                HStack {
                    Picker("Keep saved scans per folder", selection: Binding(get: { retentionCount }, set: { value in
                        if value == 0 { retentionCount = 0 } else { proposedRetention = value }
                    })) {
                        Text("Until I review them").tag(0)
                        ForEach([7, 14, 30], id: \.self) { Text("Latest \($0)").tag($0) }
                    }.frame(maxWidth: 340).disabled(m.busy || m.snapshotBusy || retentionBusy)
                    if retentionBusy { ProgressView().controlSize(.small) }
                }
                if let warning = m.snapshotHistoryWarning {
                    HStack {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Tints.yellow)
                        Spacer()
                        Button("try again") { Task { await m.refreshSnapshotHistory() } }.accessibilityLabel("Try Again")
                            .disabled(m.snapshotHistoryLoading)
                    }
                }
                if m.snapshotHistoryLoading && m.savedSnapshots.isEmpty {
                    ProgressView("Loading saved snapshots…").padding(.vertical, 36)
                } else if m.savedSnapshots.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("No snapshots saved yet").font(.title2.weight(.semibold))
                        Text("Run a scan to start your history. Completed scans save automatically unless disabled in Settings; Save Snapshot is also available above your results.")
                            .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                        Button(m.scan == nil ? "Go to Storage" : "Back to scan results", systemImage: "internaldrive") {
                            m.openStorage(.explore)
                        }.buttonStyle(StorageButtonStyle(prominent: true))
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .storagePanel()
                } else if let selected, let snapshot = m.savedSnapshots.first(where: { $0.id == selected }) {
                    snapshotDetail(snapshot)
                } else {
                    Text("Saved locally on this Mac. New snapshots keep file paths, sizes and modification dates for comparisons, plus top-level totals. File contents are never stored. Older records contain top-level totals only.")
                        .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(m.savedSnapshots.dropFirst(page * 12).prefix(12))) { snapshot in
                            Button { selected = snapshot.id } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Tints.mint)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(StorageLabels.location(snapshot.scan.rootPath)).font(.headline)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text("Saved " + snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(Tints.secondaryText)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 5) {
                                        Text(DiskFormat.bytes(snapshot.scan.nodes.first?.allocatedBytes ?? 0)).monospacedDigit()
                                        Text("on disk at scan time").font(.caption).foregroundStyle(Tints.secondaryText)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tints.mint)
                                }.padding(.vertical, 16).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider().overlay(Tints.mint.opacity(0.18))
                        }
                    }
                    ListPagination(page: $page, total: m.savedSnapshots.count, pageSize: 12, noun: "snapshots")
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppColors.canvas).buttonStyle(StorageButtonStyle())
        .task { await m.refreshSnapshotHistory() }
        .onChange(of: m.savedSnapshots.map(\.id)) { _, _ in page = 0 }
        .confirmationDialog("Automatically move older saved scans to Trash?", isPresented: Binding(get: { proposedRetention != nil }, set: { if !$0 { proposedRetention = nil } }), titleVisibility: .visible) {
            if let count = proposedRetention {
                Button("Keep Latest \(count) per Folder", role: .destructive) {
                    retentionCount = count; proposedRetention = nil
                    retentionBusy = true
                    Task { await m.applySnapshotRetention(); retentionBusy = false }
                }
            }
        } message: { Text("This applies now and after future scans. Only older StorageDaddy history metadata goes to Trash; scanned files stay in place. You can recover metadata from Trash or turn this policy off here.") }
        .confirmationDialog("Move this saved scan and its file index to Trash?", isPresented: Binding(get: { trashReview != nil }, set: { if !$0 { trashReview = nil } }), titleVisibility: .visible) {
            if let snapshot = trashReview {
                Button("Move Saved Scan to Trash", role: .destructive) {
                    trashSaved(snapshot)
                    trashReview = nil; selected = nil
                }
            }
        } message: { Text("Only StorageDaddy’s saved metadata is moved. Your scanned files stay in place. History stops saving at 512 scans or 2 GB until you make room.") }
    }

    private func snapshotDetail(_ snapshot: SavedScanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("all snapshots", systemImage: "chevron.left") { selected = nil }.accessibilityLabel("All snapshots")
            Text(StorageLabels.location(snapshot.scan.rootPath)).font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Text("Scanned " + snapshot.scan.started.formatted(date: .abbreviated, time: .shortened))
                .font(.callout).foregroundStyle(Tints.secondaryText)
            Text(DiskFormat.bytes(snapshot.scan.nodes.first?.allocatedBytes ?? 0))
                .font(.largeTitle.bold()).monospacedDigit().foregroundStyle(Tints.mint)
            Text("On disk when scanned. This saved record does not update when files change.")
                .foregroundStyle(Tints.secondaryText)
            if snapshot.scan.skipped > 0 {
                Label("\(snapshot.scan.skipped.formatted()) items were skipped by this scan. Saved totals are partial.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Tints.yellow)
            }
            if let warning = snapshot.archivalWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tints.yellow)
            }
            SavedSnapshotContents(snapshot: snapshot).id(snapshot.id)
            if snapshot.fullTreeVersion == 1 {
                Button("Open saved scan results", systemImage: "internaldrive") { m.openSavedScan(snapshot) }.disabled(m.busy || m.snapshotBusy || !m.staged.isEmpty)
                Text("Reopens the saved map and developer artifacts without reading your drive. Rescan to update them; cleanup always checks live files.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            ScanComparisonView(snapshot: snapshot).id(snapshot.id)
            Button("Move saved scan to Trash…", role: .destructive) { trashReview = snapshot }.disabled(m.snapshotBusy || m.busy)
        }
    }

    private func trashSaved(_ snapshot: SavedScanSnapshot) {
        guard !m.snapshotBusy, !m.busy else { return }
        do {
            try SnapshotHistoryStore.trash(id: snapshot.id, directory: m.snapshotDirectory)
            Task { await m.refreshSnapshotHistory() }
        } catch {
            let message = "Could not move all saved metadata to Trash. " + error.localizedDescription
            Task { await m.refreshSnapshotHistory(); m.snapshotHistoryWarning = message }
        }
    }
}

private struct SavedSnapshotContents: View {
    let snapshot: SavedScanSnapshot
    @State private var page = 0
    private var children: [DiskNode] {
        snapshot.scan.nodes.dropFirst().sorted {
            $0.allocatedBytes == $1.allocatedBytes ? $0.name < $1.name : $0.allocatedBytes > $1.allocatedBytes
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top-level sizes").font(.headline)
            ForEach(Array(children.dropFirst(page * 15).prefix(15))) { item in
                HStack {
                    Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(Tints.mint)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(DiskFormat.bytes(item.allocatedBytes)).monospacedDigit()
                }.padding(.vertical, 6)
            }
            if !children.isEmpty {
                ListPagination(page: $page, total: children.count, pageSize: 15, noun: "items")
            }
        }
    }
}
