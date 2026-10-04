import SwiftUI
import DiskCore

struct GitEvidenceView: View {
    let url: URL
    var load: @Sendable (URL) -> GitCheckoutEvidence = { GitCheckoutProbe.collect(at: $0) }
    @State private var evidence: GitCheckoutEvidence?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("GIT REVIEW EVIDENCE").font(.caption.weight(.semibold)).foregroundStyle(Tints.mint)
            if let evidence {
                row("Changed entries", evidence.changedEntries)
                row("Unpushed commits", evidence.unpushedCommits)
                row("Stashes", evidence.stashes)
                Text("Local checks only. No upstream means the unpushed count is unavailable. These signals never authorize cleanup.")
                    .font(.caption2).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Checking local repository…").font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
        .task(id: url) {
            evidence = nil
            let worker = Task.detached(priority: .utility) { load(url) }
            let result = await worker.value
            guard !Task.isCancelled else { return }
            evidence = result
        }
    }
    private func row(_ label: String, _ value: Int?) -> some View {
        HStack { Text(label); Spacer(); Text(value.map { $0.formatted() } ?? "Unavailable").monospacedDigit() }.font(.caption)
    }
}
