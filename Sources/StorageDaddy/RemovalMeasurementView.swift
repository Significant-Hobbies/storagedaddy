import DiskCore
import SwiftUI

struct RemovalMeasurementView: View {
    @EnvironmentObject private var m: ExplorerModel
    let scan: ScanResult
    let ids: [Int]
    @State private var report: LiveRemovalReport?
    @State private var error: String?
    @State private var running = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(report == nil ? "Measure selected paths together" : "Measure again", action: measure)
                    .disabled(m.busy || m.moves.busy || ids.isEmpty || ids.count > 20)
                if running { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel() } }
            }
            if ids.count > 20 { Text("Live joint measurement supports up to 20 paths at once.").font(.caption).foregroundStyle(Tints.secondaryText) }
            if let report {
                Text("Live metadata estimate · \(report.measuredAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Tints.secondaryText)
                LabeledContent("Potential file allocation released together", value: DiskFormat.bytes(report.total.freesBytes))
                LabeledContent("Held by names or clones elsewhere", value: DiskFormat.bytes(report.total.heldElsewhereBytes))
                LabeledContent("Uncertain shared allocation", value: DiskFormat.bytes(report.total.uncertainBytes))
                if report.incomplete { Label("Partial measurement · \(report.skippedEntries) skipped", systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow) }
                Text(report.warning).font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Tints.yellow) }
        }.padding(16).storagePanel().onDisappear { task?.cancel() }
    }
    private func measure() {
        guard !m.busy, !m.moves.busy, !running, (1...20).contains(ids.count), ids.allSatisfy({ scan.nodes.indices.contains($0) }) else { return }
        running = true; m.busy = true; report = nil; error = nil
        let paths = ids.map { scan.url(for: $0) }, exclusions = m.excludedFolders
        task = Task {
            defer { running = false; m.busy = false; task = nil }
            let worker = Task.detached(priority: .utility) { try RemovalMeasurement.measure(paths: paths, excludedFolders: exclusions) }
            do {
                let measured = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); report = measured
            } catch is CancellationError { error = "Measurement cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
}
