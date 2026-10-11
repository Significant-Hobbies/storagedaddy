import SwiftUI
import DiskCore

struct StorageAllocationDetailsView: View {
    @EnvironmentObject var m: ExplorerModel
    let node: DiskNode
    var body: some View {
        let summary = m.allocationSummary(node)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Exclusive allocation")
                Spacer()
                Text(summary?.exclusiveBytes.map(DiskFormat.bytes) ?? "Unknown").monospacedDigit()
            }
            if let summary, summary.sharedFiles > 0 {
                Label("\(summary.sharedFiles.formatted()) \(summary.sharedFiles == 1 ? "file entry shares" : "file entries share") storage", systemImage: "square.on.square")
                    .foregroundStyle(Tints.mint)
                Text("Shared blocks can be retained by other copies or snapshots. Zero attributed bytes can mean another copy owns the count; this item still contains files.")
            } else if summary?.exclusiveBytes == nil {
                Text("Rescan to measure exclusive bytes. Legacy scans, unsupported metadata and incomplete folders have an unknown recovery estimate.")
            }
            Text("Exclusive bytes exclude known sharing and hard links. They describe this scan, not a guarantee of space recovered after emptying Trash.")
        }.font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}

struct ChromeSigningCopiesView: View {
    @EnvironmentObject var m: ExplorerModel
    let nodeID: Int
    var body: some View {
        if let scan = m.scan {
            let location = ChromeSigningClones.location(path: scan.url(for: nodeID).path)
            VStack(alignment: .leading, spacing: 8) {
                Label("Chrome signing copies", systemImage: "square.on.square").font(.headline).foregroundStyle(Tints.mint)
                Text("Temporary Chrome app copies keep code-signature checks working during updates. They share APFS blocks; browser profiles and browsing history live elsewhere.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                Text("Quit Chrome first. Copies modified within 24 hours and copies that cannot be verified are kept.")
                    .font(.caption).foregroundStyle(Tints.yellow)
                if location == .store {
                    HStack {
                        Text("\(ChromeSigningClones.copyIDs(in: scan, storeID: nodeID).count.formatted()) signing copies found").font(.caption)
                        Spacer()
                        Button("review signing copies", systemImage: "tray.and.arrow.down") { m.stageChromeSigningCopies(nodeID) }
                            .accessibilityLabel("Review signing copies").buttonStyle(StorageButtonStyle(prominent: true))
                            .disabled(m.busy || m.monitoring)
                    }
                } else {
                    Text("Review a whole signing copy from the inspector. Individual bundle files are protected from cleanup.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }
            }.padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
        }
    }
}
