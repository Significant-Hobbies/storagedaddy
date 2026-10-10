import SwiftUI
import SaaSMakerUI
import DiskCore

struct LiveScanView: View {
    @EnvironmentObject var m: ExplorerModel
    let progress: ScanProgress
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("LIVE DISCOVERY").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Tints.mint)
                HStack { SMSectionHeader("Your storage, taking shape.", size: 32).accessibilityLabel("Your storage, taking shape."); DoodleArt(topic: .explore).frame(width: 82, height: 82); Spacer() }
                Text("Results grow as folders are explored. Final totals and developer insights appear when the scan finishes.").foregroundStyle(Tints.secondaryText)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(DiskFormat.bytes(progress.allocatedBytes)).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Tints.mint)
                        Text("on disk found so far").foregroundStyle(Tints.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(SpeedFormat.duration(progress.elapsed)).font(.title.monospacedDigit())
                        Text("\(progress.files.formatted()) files discovered").foregroundStyle(Tints.secondaryText)
                        Text(SpeedFormat.entriesPerSecond(entries: progress.entries, elapsed: progress.elapsed))
                            .monospacedDigit().foregroundStyle(Tints.mint)
                        Text(processDiskReadRateText).monospacedDigit().foregroundStyle(Tints.secondaryText)
                            .help("Live metadata I/O charged by macOS to storagedaddy. This is not SSD throughput. Entries per second helps compare scans with similar scope on this Mac.")
                        if let rss = m.scanPeakRSS { Text("\(DiskFormat.bytes(Int64(clamping: rss))) sampled peak RSS").font(.caption).foregroundStyle(Tints.secondaryText) }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Largest locations so far").font(.title2.weight(.semibold)); Spacer(); Text("PARTIAL TOTALS").font(.caption).foregroundStyle(Tints.secondaryText) }
                    if progress.locations.isEmpty {
                        Text("Reading the first folders…").foregroundStyle(Tints.secondaryText)
                    }
                    ForEach(progress.locations) { location in
                        let color = Tints.forLocation(location.name)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                                Text(StorageLabels.location(location.name)).lineLimit(1)
                                Spacer()
                                Text(DiskFormat.bytes(location.allocatedBytes)).monospacedDigit().foregroundStyle(color)
                            }
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.85))
                                    .frame(width: geometry.size.width * CGFloat(location.allocatedBytes) / CGFloat(max(1, progress.locations.first?.allocatedBytes ?? 1)))
                            }.frame(height: 5)
                        }.padding(.vertical, 5)
                    }
                }
                if progress.skipped > 0 { Text("\(progress.skipped.formatted()) items skipped so far. Protected and unreadable locations are excluded.").font(.callout).foregroundStyle(Tints.secondaryText) }
                SizeExplanationView()
                Text("Preview only · Cleanup is available after the scan completes.").font(.caption).foregroundStyle(Tints.secondaryText)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color.black)
        .accessibilityIdentifier("live-scan-results")
    }

    private var processDiskReadRateText: String {
        guard let rate = DiskReadMetric.megabytesPerSecond(bytesRead: progress.processDiskReadBytes, elapsed: progress.elapsed) else {
            return "Metadata I/O unavailable"
        }
        return String(format: "Metadata I/O %.1f MB/s", rate)
    }
}

struct SizeExplanationView: View {
    var accounting: ScanStorageAccounting? = nil
    var scan: ScanResult? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let accounting {
                Text("Why the scan differs from disk usage").font(.headline)
                if let breakdown = accounting.measuredBreakdown { Text(breakdown) }
                Text(accounting.explanation)
                Text("Capacity measured after this scan; rescan to update.")
            }
            if let scan, scan.skipped > 0 {
                Text("Scan coverage").font(.headline)
                Text(scan.coverageExplanation)
            }
            Text("Two ways to measure size").font(.headline)
            Text("On disk is the space allocated to a file. Logical is the size of its contents as reported to apps.")
            Text("For example, a sparse disk image can have a logical size of 100 GB while occupying only 8 GB on disk. Small files can occupy more space than their contents because storage is allocated in blocks.")
            Text("Compression and cloud-only files can also make the numbers differ. Hard-linked files share storage, counted once here. APFS clones and snapshots can share blocks too, so on-disk totals are not a guarantee of space freed by cleanup.")
        }.font(.callout).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}
