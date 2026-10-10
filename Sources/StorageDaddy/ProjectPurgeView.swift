import SwiftUI
import SaaSMakerUI
import DiskCore

enum ProjectPurgeViewStatus: Equatable {
    case ready
    case loading
    case error(String)
    case idle(String)
}

/// Separate inspection focus from explicit cleanup selection. Used by the
/// native view and deterministic fixtures; construction selects nothing.
struct ProjectPurgeSelectionState {
    var focusedProjectID: Int?
    private(set) var artifactIDs: Set<Int> = []

    mutating func set(_ id: Int, selected: Bool, records: [ProjectPurgeRecord]) {
        if selected, !ProjectPurgeReview.stageableSelection([id], in: records).isEmpty {
            artifactIDs.insert(id)
        } else { artifactIDs.remove(id) }
    }

    mutating func reset() { focusedProjectID = nil; artifactIDs = [] }

    @discardableResult
    func stage(records: [ProjectPurgeRecord], status: ProjectPurgeViewStatus, callback: ([Int]) -> Void) -> Bool {
        guard status == .ready else { return false }
        let ids = ProjectPurgeReview.stageableSelection(artifactIDs, in: records)
        guard !ids.isEmpty else { return false }
        callback(ids)
        return true
    }
}

/// Saving a plan is separate from artifact selection and staging. Acknowledgement
/// is deliberately false when opening even an existing plan for editing.
struct ProjectPurgeRecoveryPlanState: Identifiable {
    let artifactID: Int
    let existingPlan: String?
    var text: String { didSet { ownerReviewed = false } }
    var ownerReviewed = false
    var id: Int { artifactID }
    var trimmedPlan: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { ownerReviewed && !trimmedPlan.isEmpty }

    init(artifactID: Int, existingPlan: String? = nil) {
        self.artifactID = artifactID
        self.existingPlan = existingPlan
        self.text = existingPlan ?? ""
    }

    @discardableResult
    func submit(callback: ((Int, String?) -> Void)?) -> Bool {
        guard canSubmit, let callback else { return false }
        callback(artifactID, trimmedPlan)
        return true
    }

    @discardableResult
    func clear(callback: ((Int, String?) -> Void)?) -> Bool {
        guard existingPlan != nil, let callback else { return false }
        callback(artifactID, nil)
        return true
    }
}

struct ProjectPurgeRecoveryPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProjectPurgeRecoveryPlanState
    var artifactName: String = "Artifact"
    let onRecoveryPlan: (Int, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("User-reviewed recovery plan")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(artifactName).font(.headline).foregroundStyle(Tints.mint).textSelection(.enabled)
            Text("Describe how you would recreate or restore this artifact, including the source and tools you need. This records your review; it does not prove rebuildability or successful restoration.")
                .foregroundStyle(Tints.secondaryText)
            TextEditor(text: $draft.text)
                .scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 130)
                .background(Tints.mint.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(0.3)))
                .accessibilityLabel("Recovery plan")
            Toggle("I reviewed this plan and accept responsibility for recovery.", isOn: $draft.ownerReviewed)
                .toggleStyle(.checkbox)
            Text("Saving does not select or stage this artifact. Key, Git, link and workspace modification protections still apply.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            HStack {
                if draft.existingPlan != nil {
                    Button("clear saved plan") {
                        if draft.clear(callback: onRecoveryPlan) { dismiss() }
                    }.accessibilityLabel("Clear saved plan").buttonStyle(StorageButtonStyle())
                }
                Spacer()
                Button("cancel") { dismiss() }.accessibilityLabel("Cancel").buttonStyle(StorageButtonStyle())
                Button("save reviewed plan") {
                    if draft.submit(callback: onRecoveryPlan) { dismiss() }
                }.accessibilityLabel("Save reviewed plan")
                .buttonStyle(StorageButtonStyle(prominent: true))
                .disabled(!draft.canSubmit)
            }
        }
        .padding(24).frame(width: 520)
        .background(Color.black)
    }
}

/// A Map & inspector companion. The root integrates this beside the existing
/// disk map. Artifact staging goes through preflight; recovery-plan callbacks
/// leave persistence and review reconstruction to the integration.
struct ProjectPurgeView: View {
    let records: [ProjectPurgeRecord]
    let scan: ScanResult?
    let status: ProjectPurgeViewStatus
    let onRecoveryPlan: ((Int, String?) -> Void)?
    let onRetry: (() -> Void)?
    let onStageArtifactIDs: ([Int]) -> Void

    @State private var selection = ProjectPurgeSelectionState()
    @State private var sort: ProjectPurgeSort = .size
    @State private var recoveryDraft: ProjectPurgeRecoveryPlanState?
    @State private var availableWidth: CGFloat = 0

    init(records: [ProjectPurgeRecord], scan: ScanResult?, status: ProjectPurgeViewStatus,
         initialFocusedProjectID: Int? = nil, onRecoveryPlan: ((Int, String?) -> Void)? = nil, onRetry: (() -> Void)? = nil, onStageArtifactIDs: @escaping ([Int]) -> Void) {
        self.records = records; self.scan = scan; self.status = status
        self.onRecoveryPlan = onRecoveryPlan; self.onStageArtifactIDs = onStageArtifactIDs
        self.onRetry = onRetry
        _selection = State(initialValue: ProjectPurgeSelectionState(focusedProjectID: records.contains { $0.id == initialFocusedProjectID } ? initialFocusedProjectID : nil))
    }

    private var selectedIDs: [Int] {
        ProjectPurgeReview.stageableSelection(selection.artifactIDs, in: records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    SMSectionHeader("Project artifacts", size: 28).accessibilityLabel("Project artifacts")
                    Text("Keep the workspace. Review dependencies and generated outputs in context.")
                        .foregroundStyle(Tints.secondaryText)
                }
                Spacer()
                Button("Stage \(selectedIDs.count) \(selectedIDs.count == 1 ? "artifact" : "artifacts")") {
                    selection.stage(records: records, status: status, callback: onStageArtifactIDs)
                }
                .buttonStyle(StorageButtonStyle(prominent: true))
                .disabled(status != .ready || scan == nil || selectedIDs.isEmpty)
                .help("Send explicitly selected artifact IDs to the existing cleanup preflight. Nothing is deleted here.")
            }
            switch status {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Reviewing project evidence…") }
            case let .error(message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.coral)
                if let onRetry { Button("refresh project evidence", action: onRetry).accessibilityLabel("Refresh project evidence") }
                else { Text("Use Refresh project evidence above this panel.").font(.caption).foregroundStyle(Tints.secondaryText) }
            case let .idle(message): Text(message).foregroundStyle(Tints.secondaryText)
            case .ready:
                if scan == nil { Text("Scan a folder to review project artifacts.") }
                else if records.isEmpty { Text("No project signatures were found in this scan.") }
                else { reviewLayout }
            }
            Text("Modified dates describe writes, not last use. Staging requires Git evidence and a user-reviewed recovery plan or verified restoration evidence.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .padding(20)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.18)))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: reviewIdentity) { _, _ in selection.reset(); recoveryDraft = nil }
        .onChange(of: status) { _, _ in selection.reset(); recoveryDraft = nil }
        .sheet(item: $recoveryDraft) { draft in
            ProjectPurgeRecoveryPlanSheet(draft: draft, artifactName: scan.flatMap {
                $0.nodes.indices.contains(draft.artifactID) ? $0.nodes[draft.artifactID].name : nil
            } ?? "Artifact") { id, plan in
                guard status == .ready, scan != nil,
                      records.contains(where: { $0.artifacts.contains(where: { $0.id == id }) }) else { return }
                onRecoveryPlan?(id, plan)
            }
        }
    }

    private var reviewLayout: some View {
        Group {
            if availableWidth >= 740 {
                HStack(alignment: .top, spacing: 18) {
                ledger.frame(width: 300)
                inspector.frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) { ledger; inspector }
            }
        }
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Sort projects", selection: $sort) {
                ForEach(ProjectPurgeSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(ProjectPurgeReview.sorted(records, by: sort)) { record in
                        Button { selection.focusedProjectID = record.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(Tints.mint)
                                    Text(record.project.name).font(.headline).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(DiskFormat.bytes(record.candidateBytes)).monospacedDigit()
                                }
                                Text(modifiedLabel(record)).font(.caption).foregroundStyle(Tints.secondaryText)
                                Text("\(record.artifacts.count) \(record.artifacts.count == 1 ? "candidate" : "candidates") · \(record.stageableArtifactIDs.count) eligible for preflight")
                                    .font(.caption).foregroundStyle(Tints.secondaryText)
                                GeometryReader { geometry in
                                    Capsule().fill(Tints.mint.opacity(0.12))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(Tints.mint).frame(width: geometry.size.width * footprintFraction(record))
                                        }
                                }.frame(height: 4)
                                .accessibilityLabel("Candidate artifact footprint relative to largest project")
                            }
                            .padding(12)
                            .background(selection.focusedProjectID == record.id ? Tints.mint.opacity(0.08) : Color.black,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection.focusedProjectID == record.id ? Tints.mint : Tints.mint.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.focusedProjectID == record.id ? .isSelected : [])
                    }
                }
            }.frame(height: min(420, CGFloat(records.count) * 118))
        }
    }

    @ViewBuilder private var inspector: some View {
        if let record = records.first(where: { $0.id == selection.focusedProjectID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Workspace inspector", systemImage: "scope").font(.caption).foregroundStyle(Tints.mint)
                    Text(record.project.name).font(.system(size: 23, weight: .semibold, design: .rounded))
                    if let scan, scan.nodes.indices.contains(record.id) {
                        Text(scan.url(for: record.id).path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("Workspace stays intact · " + modifiedLabel(record)).font(.callout)
                    Text("Project signatures: " + record.signatures.joined(separator: ", "))
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                    if !record.protections.contains(.unverifiedGit) {
                        Label("Git tracking checked for this workspace", systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(Tints.mint)
                    }
                    reasons(record.protections)
                    if record.artifacts.isEmpty {
                        Text("No existing classified artifact roots belong to this project.").foregroundStyle(Tints.secondaryText)
                    }
                    ForEach(record.artifacts) { artifact in artifactRow(artifact) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 500)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "scope").font(.title).foregroundStyle(Tints.mint)
                Text("Choose a workspace to inspect").font(.headline)
                Text("The ledger shows existing artifact footprints. Inspect protections, then select individual artifacts to stage for preflight.")
                    .foregroundStyle(Tints.secondaryText)
            }.frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        }
    }

    private func artifactRow(_ artifact: ProjectPurgeArtifact) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(get: { selection.artifactIDs.contains(artifact.id) }, set: {
                selection.set(artifact.id, selected: $0, records: records)
            })) {
                HStack {
                    Text(scan.flatMap { $0.nodes.indices.contains(artifact.id) ? $0.nodes[artifact.id].name : nil } ?? artifact.finding.tool)
                        .font(.headline)
                    Spacer()
                    Text(DiskFormat.bytes(artifact.allocatedBytes)).monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!artifact.canStage || status != .ready)
            Text(artifact.finding.evidence).font(.caption).foregroundStyle(Tints.secondaryText)
            Text(artifact.finding.consequence).font(.callout).foregroundStyle(Tints.secondaryText)
            if let evidence = artifact.rebuildabilityEvidence, !evidence.isEmpty {
                Label("Verified restoration evidence: " + evidence, systemImage: "checkmark.shield").font(.caption).foregroundStyle(Tints.mint)
            }
            if let plan = artifact.userReviewedRecoveryPlan {
                Label("User-reviewed recovery plan: " + plan, systemImage: "text.document")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            if onRecoveryPlan != nil {
                Button(artifact.userReviewedRecoveryPlan == nil ? "Add recovery plan" : "Edit recovery plan") {
                    recoveryDraft = ProjectPurgeRecoveryPlanState(artifactID: artifact.id, existingPlan: artifact.userReviewedRecoveryPlan)
                }
                .buttonStyle(StorageButtonStyle())
                .disabled(status != .ready || scan == nil)
            }
            reasons(artifact.protections)
        }
        .padding(12)
        .background(Tints.mint.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(0.18)))
    }

    private func reasons(_ protections: [ProjectPurgeProtection]) -> some View {
        ForEach(protections, id: \.self) { reason in
            Label(reason.rawValue, systemImage: "lock.shield").font(.caption).foregroundStyle(Tints.secondaryText)
        }
    }

    private func modifiedLabel(_ record: ProjectPurgeRecord) -> String {
        record.newestModified.map { "Newest modified " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Modified date unknown"
    }

    private func footprintFraction(_ record: ProjectPurgeRecord) -> Double {
        let largest = records.map(\.candidateBytes).max() ?? 0
        return largest > 0 ? max(0, min(1, Double(record.candidateBytes) / Double(largest))) : 0
    }

    // Evidence/scan changes clear both inspection focus and every selection.
    private var reviewIdentity: String {
        "\(scan?.rootPath ?? "")|\(scan?.started.timeIntervalSince1970 ?? 0)|" + records.map {
            "\($0.id):\($0.newestModified?.timeIntervalSince1970 ?? 0):" + $0.artifacts.map {
                "\($0.id):\($0.allocatedBytes):\($0.rebuildabilityEvidence ?? ""):\($0.userReviewedRecoveryPlan ?? ""):\($0.protections.map(\.rawValue).joined())"
            }.joined(separator: ";")
        }.joined(separator: "|")
    }
}
