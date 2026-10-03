import DiskCore
import SwiftUI

/// Parent supplies immutable metadata and routes explicit review requests through preflight.
/// Inspector selection does not stage a cleanup item.
struct AppLeftoverReviewView: View {
    let result: AppLeftoverReviewResult
    let reviewEnabled: Bool
    let onInspect: (AppLeftoverRecord) -> Void
    let onReview: (AppLeftoverRecord) -> Void
    @State private var inspectedPath: String?

    init(result: AppLeftoverReviewResult, reviewEnabled: Bool, initialInspectedPath: String? = nil,
         onInspect: @escaping (AppLeftoverRecord) -> Void, onReview: @escaping (AppLeftoverRecord) -> Void) {
        self.result = result; self.reviewEnabled = reviewEnabled
        self.onInspect = onInspect; self.onReview = onReview
        _inspectedPath = State(initialValue: result.records.contains { $0.path == initialInspectedPath } ? initialInspectedPath : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App data to review").font(.title2.weight(.semibold))
            Text("Compare Library data with apps found in standard app folders. Unattributed means no match was found; ownership and removal safety remain unknown. Nothing is selected automatically.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            Text("App folders: \(result.inventoryCompleteness.rawValue) · checked \(result.inventoryCheckedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown")")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            if !result.absenceEvidenceAvailable {
                Text("Reference coverage is insufficient. No absence-based candidates are offered.")
                    .font(.callout).foregroundStyle(Tints.yellow)
            }
            if result.scanIncomplete {
                Text("Scan coverage is partial. Allocated upper bounds are unknown.")
                    .font(.callout).foregroundStyle(Tints.yellow)
            }
            if result.records.isEmpty {
                Text("No eligible direct Library roots in this scan.")
                    .foregroundStyle(Tints.secondaryText).padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.records) { record in
                            Button { inspectedPath = record.path } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: record.status == .protected ? "shield" : "questionmark.folder")
                                        .foregroundStyle(Tints.mint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                                        Text(record.category + " · " + label(record.status))
                                            .font(.caption).foregroundStyle(Tints.secondaryText)
                                    }
                                    Spacer(minLength: 10)
                                    Text(record.allocatedUpperBound.map { DiskFormat.bytes($0) + " upper bound" } ?? "Size unknown")
                                        .font(.caption).monospacedDigit().foregroundStyle(Tints.secondaryText)
                                }
                                .padding(10).contentShape(Rectangle())
                                .background(inspectedPath == record.path ? Tints.mint.opacity(0.08) : Color.black)
                            }
                            .buttonStyle(.plain)
                            .help(record.path)
                            .accessibilityLabel(record.name + ", " + label(record.status))
                            .accessibilityAddTraits(inspectedPath == record.path ? .isSelected : [])
                            Rectangle().fill(Tints.mint.opacity(0.14)).frame(height: 1)
                        }
                    }
                }.frame(height: min(280, CGFloat(result.records.count) * 64))
            }
            if let record = result.records.first(where: { $0.path == inspectedPath }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.name).font(.headline).foregroundStyle(Tints.mint)
                        if record.status == .unattributedCandidate {
                            Text("No matching app was found in the checked folders. Ownership, current use and recoverability are unknown.").font(.callout)
                        } else { Text(record.reason).font(.callout) }
                        Text("Allocated upper bound is scanned disk allocation, not reclaimable space.")
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                        DisclosureGroup("Matching evidence and limits") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.reason)
                                ForEach(record.evidence, id: \.self) { Text($0) }
                                ForEach(record.unknowns, id: \.self) { Text($0) }
                            }.font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        HStack {
                            Button("Inspect in scan") { onInspect(record) }
                                .buttonStyle(StorageButtonStyle())
                            if record.status == .unattributedCandidate && result.absenceEvidenceAvailable {
                                Button("Request cleanup review") { onReview(record) }
                                    .buttonStyle(StorageButtonStyle())
                                    .disabled(!reviewEnabled)
                            }
                        }
                    }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 250)
            }
        }
        .padding(20).background(Color.black, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.18)))
    }

    private func label(_ status: AppLeftoverRecord.Status) -> String {
        switch status {
        case .protected: "Protected"
        case .unidentified: "Ownership unknown"
        case .unattributedCandidate: "Unattributed candidate"
        }
    }
}
