import SwiftUI
import DiskCore

/// Calculated state only: the owner schedules/cancels background refreshes.
struct FileAgeHistogramView: View {
    let histogram: FileAgeHistogram?
    let granularity: FileAgeGranularity
    var isRefreshing = false
    var onGranularityChange: (FileAgeGranularity) -> Void
    var onSelectNode: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Storage by last modified date").font(.headline)
                Text("Modification dates do not tell you when a file was last opened. Age alone is not a cleanup recommendation.")
                    .font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                Picker("Calendar intervals", selection: Binding(get: { granularity }, set: { onGranularityChange($0) })) {
                    ForEach(FileAgeGranularity.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420).disabled(isRefreshing)
                if isRefreshing { Text("Updating modification dates…").font(.caption).foregroundStyle(Tints.secondaryText) }
                if let histogram {
                    Text("\(histogram.totalFiles.formatted()) files · \(DiskFormat.bytes(histogram.totalBytes)) \(histogram.allocated ? "on disk" : "logical")")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                    if let p = histogram.percentiles {
                        HStack(spacing: 24) {
                            percentile("50%", p.p50)
                            percentile("90%", p.p90)
                            percentile("95%", p.p95)
                        }
                        Text("Byte-weighted ages: each share of dated bytes was last modified within this age. Unknown and future dates are excluded.")
                            .font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Age percentiles unavailable: no positive-byte files with known, non-future dates.")
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                    let maximum = max(1, histogram.buckets.map(\.bytes).max() ?? 1)
                    ForEach(histogram.buckets.filter { $0.id < 24 || $0.count > 0 }) { bucket in
                        Button { if let id = bucket.largestID { onSelectNode(id) } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(label(bucket)).lineLimit(1)
                                    Spacer()
                                    Text("\(bucket.count.formatted()) \(bucket.count == 1 ? "file" : "files")").font(.caption).foregroundStyle(Tints.secondaryText)
                                    Text(DiskFormat.bytes(bucket.bytes)).monospacedDigit()
                                }
                                GeometryReader { geometry in
                                    RoundedRectangle(cornerRadius: 3).fill(Tints.mint.opacity(0.75))
                                        .frame(width: geometry.size.width * Double(bucket.bytes) / Double(maximum))
                                }.frame(height: 8)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Select the largest file in this interval to inspect it.")
                    }
                    if histogram.totalFiles == 0 { Text("No files in this folder.").foregroundStyle(Tints.secondaryText) }
                } else if !isRefreshing { Text("No calculated modification dates.").foregroundStyle(Tints.secondaryText) }
            }.padding(16)
        }.foregroundStyle(Tints.secondaryText).background(Color.black)
    }

    private func percentile(_ title: String, _ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title + " of dated bytes").font(.caption).foregroundStyle(Tints.secondaryText)
            Text(String(format: "%.1f days", seconds / 86400)).font(.title3).monospacedDigit().foregroundStyle(Tints.mint)
        }
    }
    private func label(_ bucket: FileAgeBucket) -> String {
        switch bucket.id {
        case 24: return "Earlier than displayed intervals"
        case 25: return "Unknown modification date"
        case 26: return "Future modification date"
        default:
            guard let histogram, let start = bucket.start, let end = bucket.end else { return "Unknown modification date" }
            let formatter = DateFormatter()
            formatter.calendar = histogram.calendar
            formatter.timeZone = histogram.calendar.timeZone
            formatter.dateFormat = histogram.granularity == .yearly ? "yyyy" : "MMM yyyy"
            let first = formatter.string(from: start)
            if histogram.granularity == .quarterly {
                return first + " – " + formatter.string(from: end.addingTimeInterval(-1))
            }
            return first
        }
    }
}
