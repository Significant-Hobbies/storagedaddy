import DiskCore
import SwiftUI
import SaaSMakerUI

/// Display only. The dashboard owner injects fixture/live values and owns the
/// sampling lifetime; this view does not poll, inventory, persist or read files.
struct StorageDashboardMetricsView: View {
    let volumes: [MountedVolumeInfo]
    let rates: StorageDashboardMetrics.IORates
    let score: StorageDashboardMetrics.Score
    /// Name of the capacity pool/volume whose score inputs were supplied.
    let scoreScope: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onReviewSnapshots: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("storage metrics").accessibilityLabel("STORAGE METRICS")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Tints.mint)
                Spacer()
                Button(action: onRefresh) {
                    Label(isRefreshing ? "refreshing…" : "refresh", systemImage: "arrow.clockwise")
                        .accessibilityLabel(isRefreshing ? "Refreshing…" : "Refresh")
                }
                .disabled(isRefreshing)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { scoreCard; ioCard }
                VStack(alignment: .leading, spacing: 16) { scoreCard; ioCard }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Mounted volumes · inodes and block I/O").font(.headline)
                Text("Filesystem-reported counts. APFS may not expose a fixed inode capacity.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
                if volumes.isEmpty {
                    Text("Volume measurements unavailable").foregroundStyle(Tints.secondaryText)
                }
                ForEach(volumes, id: \.mountPoint) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(volume.name) · \(volume.fsDisplayName)").font(.callout.weight(.semibold))
                        if let inodes = StorageDashboardMetrics.inodes(total: volume.inodeTotal, free: volume.inodeFree) {
                            Text("\(inodes.used.formatted()) of \(inodes.total.formatted()) inodes used · \(inodes.usedRatio.formatted(.percent.precision(.fractionLength(1))))")
                                .font(.callout).monospacedDigit()
                        } else {
                            Text("Inode usage unavailable").font(.callout).foregroundStyle(Tints.secondaryText)
                        }
                        if let traffic = rates.volumes.first(where: { $0.bsdName == volume.bsdName }) {
                            Text("APFS volume block I/O · \(volume.bsdName)").font(.caption)
                            HStack(alignment: .top, spacing: 24) {
                                rateRow("Read", rate: traffic.read)
                                rateRow("Write", rate: traffic.write)
                            }
                            if let interval = traffic.interval {
                                Text("Two samples · \(interval.formatted(.number.precision(.fractionLength(1)))) s interval").font(.caption)
                            }
                        } else {
                            Text("APFS volume I/O counters unavailable for this exact mounted device.").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .metricCard()
        }
        .foregroundStyle(Tints.secondaryText)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage readiness · \(scoreScope)").font(.headline)
            if score.isComplete, let points = score.earnedPoints {
                Text("\(points.formatted(.number.precision(.fractionLength(0)))) / 100")
                    .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Tints.mint)
            } else {
                Text("Assessment incomplete").font(.title2.weight(.semibold))
            }
            Text("\(score.measuredCount) of 4 components measured · \(score.coverage.formatted(.percent)) coverage")
                .font(.callout)
            ForEach(score.components) { component in
                HStack(alignment: .firstTextBaseline) {
                    Text(component.id)
                    Spacer()
                    Text(component.points.map { "\($0.formatted(.number.precision(.fractionLength(1)))) / 25" } ?? "Unknown")
                        .monospacedDigit()
                }
                .font(.callout)
                .help(component.explanation)
                .accessibilityElement(children: .combine)
                .accessibilityHint(component.explanation)
            }
            Text("Heuristic, not a health diagnosis. The overall score is withheld until every component is measured. Unknown is not a failure. Snapshots are review context.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("How the score is calculated") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(score.components) { component in
                        Text("\(component.id): \(component.explanation)")
                    }
                    Text("Equal weights; fixed 100-point denominator. Free and purgeable ratios use the selected capacity pool. Wear must be associated explicitly with its physical device.")
                }
                .font(.caption).padding(.top, 6)
            }
            Button("Review local snapshots", action: onReviewSnapshots)
        }
        .metricCard()
    }

    private var ioCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rates.attribution).font(.headline)
            rateRow("Read", rate: rates.read)
            rateRow("Write", rate: rates.write)
            if let interval = rates.interval {
                Text("Two samples · \(interval.formatted(.number.precision(.fractionLength(1)))) s interval")
                    .font(.caption).monospacedDigit()
            }
            Text("Observed non-disk-image drivers only; coverage can be incomplete. These are byte-counter deltas, not lifetime totals or volume traffic.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text(rates.perVolumeUnavailableReason).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .metricCard()
    }

    private func rateRow(_ title: String, rate: StorageDashboardMetrics.Rate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            switch rate {
            case .measured(let bytes):
                Text("\((bytes / 1_000_000).formatted(.number.precision(.fractionLength(2)))) MB/s")
                    .font(.title3.weight(.semibold)).foregroundStyle(Tints.mint).monospacedDigit()
            case .unavailable(let reason):
                Text(reason.rawValue).font(.callout).foregroundStyle(Tints.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func metricCard() -> some View {
        SMCard { self }
    }
}
