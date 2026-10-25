import DiskCore
import SwiftUI

struct NpxCacheReviewView: View {
    @EnvironmentObject private var m: ExplorerModel
    @State private var showAll = false
    @State private var entries: [NpxCacheEntry] = []
    private var cache: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("npx cache entries").font(.title2.weight(.semibold))
                Spacer()
                Button("Scan npx cache") { m.start(cache, destination: .developer) }.disabled(m.busy)
            }
            Text("Review individual downloaded tool versions. Cleanup checks open files and running CLI names, including tools that already closed their scripts. Modification dates do not prove an entry is unused.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if entries.isEmpty {
                Text("Scan the npx cache to review its entries. Active tools are kept; uncertain package metadata blocks cleanup.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
            }
            ForEach(Array(entries.prefix(showAll ? entries.count : 10))) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.packageSummary ?? "Package metadata unavailable").font(.callout).lineLimit(2)
                        Text(entry.name).font(.caption.monospaced()).foregroundStyle(Tints.secondaryText)
                        Text("Modified " + entry.modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                    Spacer()
                    Text(DiskFormat.bytes(entry.allocatedBytes)).monospacedDigit()
                    Button(m.staged.contains(entry.id) ? "Added" : "Add to Cleanup") { m.stage(entry.id) }
                        .disabled(m.busy || m.monitoring || m.staged.contains(entry.id))
                }.padding(.vertical, 5)
            }
            if entries.count > 10 {
                Button(showAll ? "Show fewer entries" : "Show all \(entries.count) entries") { showAll.toggle() }
            }
        }.padding(18).storagePanel()
            .task(id: m.scan?.started) {
                guard let scan = m.scan else { entries = []; return }
                let result = await Task.detached(priority: .utility) {
                    NpxCacheReview.entries(in: scan).map { original in
                        var entry = original
                        if !Task.isCancelled { entry.packageSummary = try? NpxCacheReview.packageSummary(entry: scan.url(for: entry.id)) }
                        return entry
                    }
                }.value
                if !Task.isCancelled { entries = result }
            }
    }
}
