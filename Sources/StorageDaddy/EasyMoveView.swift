import AppKit
import SwiftUI
struct EasyMovePresentation: ViewModifier {
    @ObservedObject var model: EasyMoveModel
    func body(content: Content) -> some View {
        content.sheet(isPresented: $model.isPresented) { EasyMoveView(model: model) }
    }
}
import DiskCore

@MainActor
final class EasyMoveModel: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var plan: EasyMovePlan?
    @Published private(set) var batchPlans: [EasyMovePlan] = []
    @Published private(set) var records: [EasyMoveRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    private var store: EasyMoveStore?
    private var operation: Task<Void, Never>?
    var operationAllowed: () -> Bool = { true }

    func review(source: URL, expected: DiskNode? = nil, scanRoot: URL? = nil, excludedFolders: [String] = []) {
        guard !busy, operationAllowed() else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to move \(source.lastPathComponent)"
        panel.message = "Choose a folder on the destination drive. You will review the move before any files change."
        panel.prompt = "Review Move"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isPresented = true; busy = true; error = nil; status = "Checking current use and verifying every file…"
        plan = nil; batchPlans = []
        operation = Task {
            do {
                let store = try getStore()
                let reviewed = try await store.prepare(source: source, destinationFolder: destination,
                    excludedFolders: excludedFolders, expected: expected, scanRoot: scanRoot)
                try Task.checkCancellation()
                plan = reviewed; status = nil
            } catch is CancellationError { status = "Review cancelled. No files moved." }
            catch { self.error = error.localizedDescription; status = nil }
            busy = false; operation = nil
            await reload()
        }
    }

    func reviewCopies(ids: [Int], scan: ScanResult, excludedFolders: [String]) {
        guard !busy, operationAllowed(), !ids.isEmpty else { return }
        guard ids.count <= 200, Set(ids).count == ids.count,
              ids.allSatisfy({ scan.nodes.indices.contains($0) && !scan.nodes[$0].isDirectory && !scan.nodes[$0].isSymlink && scan.nodes[$0].parent != nil }) else {
            error = "Choose up to 200 ordinary duplicate copies per move."; isPresented = true; return
        }
        let panel = NSOpenPanel(); panel.title = "Move selected duplicate copies"
        panel.message = "Review each destination before moving. At least one copy stays in each duplicate group. Original paths will not retain links."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Review Copies"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        plan = nil; batchPlans = []; isPresented = true; busy = true; error = nil; status = "Verifying selected copies…"
        operation = Task {
            do {
                let store = try getStore()
                var plans: [EasyMovePlan] = []
                for id in ids {
                    let node = scan.nodes[id]
                    let name = "\(id)-" + node.name
                    plans.append(try await store.prepare(source: scan.url(for: id), destinationFolder: destination,
                        excludedFolders: excludedFolders, expected: node, scanRoot: URL(fileURLWithPath: scan.rootPath), leaveSourceLink: false, destinationName: name))
                }
                try Task.checkCancellation(); batchPlans = plans; status = nil
            } catch { self.error = error.localizedDescription; status = nil }
            busy = false; operation = nil
        }
    }
    func confirmBatch() {
        guard !busy, operationAllowed(), !batchPlans.isEmpty else { return }
        let plans = batchPlans; busy = true; error = nil
        operation = Task {
            var completed = 0
            do {
                let store = try getStore()
                for plan in plans {
                    try Task.checkCancellation()
                    status = "Moving \(completed + 1) of \(plans.count)…"
                    _ = try await store.execute(reviewedPlan: plan); completed += 1
                }
                status = "Moved \(completed) copies. Restore individual moves from history. Rescan for current totals."
            } catch { self.error = "Moved \(completed) of \(plans.count). " + error.localizedDescription; status = nil }
            batchPlans = []; busy = false; operation = nil; await reload()
        }
    }

    func showHistory() { guard !busy else { return }; isPresented = true; plan = nil; batchPlans = []; error = nil; status = nil; Task { await reload() } }
    func discardReview() { guard !busy else { return }; plan = nil; batchPlans = []; status = nil }
    func cancel() { operation?.cancel(); status = "Cancellation requested. Waiting for the current safe stopping point…" }

    func confirmMove() {
        guard !busy, operationAllowed(), let plan else { return }
        busy = true; error = nil; status = "Verifying and moving… Keep the destination drive connected."
        operation = Task {
            do {
                let store = try getStore()
                _ = try await store.execute(reviewedPlan: plan)
                self.plan = nil
                status = plan.sameVolume ? "Moved. The original path now links to the destination. A move on the same volume does not reclaim space." : "Moved and verified. The original path now links to the destination."
            } catch is CancellationError {
                self.plan = nil; status = "Move stopped. Use Restore in move history to recover any completed steps."
            } catch { self.plan = nil; self.error = error.localizedDescription; status = nil }
            busy = false; operation = nil
            await reload()
        }
    }

    func restore(_ record: EasyMoveRecord) {
        guard !busy, operationAllowed() else { return }
        busy = true; error = nil; status = "Restoring the destination’s current contents…"
        operation = Task {
            do {
                let store = try getStore()
                let result = try await store.rollback(recordID: record.id)
                status = result.message ?? "Restored to the original location."
            } catch is CancellationError { status = "Restore stopped. Both copies remain protected by the recovery journal." }
            catch { self.error = error.localizedDescription; status = nil }
            busy = false; operation = nil
            await reload()
        }
    }

    func reload() async {
        do { records = try await getStore().history() }
        catch { self.error = error.localizedDescription }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    private func getStore() throws -> EasyMoveStore {
        if let store { return store }
        let created = try EasyMoveStore(journalDirectory: EasyMoveStore.defaultJournalDirectory)
        store = created; return created
    }
}

struct EasyMoveView: View {
    @ObservedObject var model: EasyMoveModel
    @State private var acknowledged = false
    @State private var restoreReview: EasyMoveRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.plan == nil ? "Easy Move" : "Review move").font(.title2.weight(.semibold))
                    Text("Move to another drive. Keep the original path working.")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                }
                Spacer()
                Button("Done") { model.isPresented = false }.disabled(model.busy)
                    .keyboardShortcut(.cancelAction)
            }
            if !model.batchPlans.isEmpty {
                Text("Review \(model.batchPlans.count) duplicate copies").font(.headline)
                Text("Moves these copies without keeping source links. Destinations include a scan identifier to avoid name collisions. Move history provides Restore.").font(.callout).foregroundStyle(Tints.secondaryText)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.batchPlans) { plan in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.source.path).lineLimit(2).truncationMode(.middle)
                                Text("→ " + plan.destination.path).lineLimit(2).truncationMode(.middle).foregroundStyle(Tints.secondaryText)
                            }.font(.caption).textSelection(.enabled)
                        }
                    }
                }.frame(maxHeight: 300)
                Toggle("I reviewed these moves and stopped tools using the files", isOn: $acknowledged)
                Button("Move Selected Copies", action: model.confirmBatch).disabled(!acknowledged || model.busy)
                Button("Cancel Review", action: model.discardReview).disabled(model.busy)
            } else if let plan = model.plan {
                review(plan)
            } else {
                history
            }
            if let status = model.status {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(status).font(.callout).foregroundStyle(Tints.secondaryText)
                }
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(Tints.yellow).textSelection(.enabled)
            }
            if model.busy {
                HStack { Spacer(); Button("Cancel operation", action: model.cancel) }
            }
        }
        .padding(28).frame(minWidth: 540, idealWidth: 640, maxWidth: 740, minHeight: 340, maxHeight: 700)
        .background(AppColors.canvas).foregroundStyle(AppColors.ink)
        .buttonStyle(StorageButtonStyle()).interactiveDismissDisabled(model.busy)
        .onChange(of: model.batchPlans.map(\.id)) { _, _ in acknowledged = false }
        .onChange(of: model.plan?.id) { _, _ in acknowledged = false }
        .task { await model.reload() }
        .confirmationDialog("Restore \(restoreReview?.plan.source.lastPathComponent ?? "item")?", isPresented: Binding(
            get: { restoreReview != nil }, set: { if !$0 { restoreReview = nil } }
        ), titleVisibility: .visible) {
            if let record = restoreReview { Button("Restore to Original Location") { model.restore(record); restoreReview = nil } }
            Button("Cancel", role: .cancel) { restoreReview = nil }
        } message: {
            Text("The destination’s current contents, including edits, return to the original location. Keep both drives connected and quit apps using this item. Enough free space is required when restoring between volumes.")
        }
    }

    @ViewBuilder private func review(_ plan: EasyMovePlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            path("From", plan.source)
            path("To", plan.destination)
            Text("\(DiskFormat.bytes(plan.bytes)) · \(plan.sameVolume ? "Same-volume move" : "Checksum-verified copy between volumes")")
                .font(.headline).foregroundStyle(Tints.mint)
            VStack(alignment: .leading, spacing: 10) {
                Label("A symbolic link at the original path points to the moved item.", systemImage: "link")
                Label("Keep the destination drive connected whenever apps need this item.", systemImage: "externaldrive")
                Label("Restore from this history to return the current contents and remove the link.", systemImage: "arrow.uturn.backward")
            }.font(.callout)
            if plan.sameVolume {
                Text("This destination is on the same volume. Moving here does not reclaim space on that volume.")
                    .font(.callout).foregroundStyle(Tints.yellow)
            }
            Text("Back up important data first. Symlinks and special files inside folders, protected paths, installed apps and detected active files are refused. An idle app can still need its files later.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            Toggle("I have quit apps and stopped builds that may use this item.", isOn: $acknowledged)
                .toggleStyle(.checkbox).font(.callout).disabled(model.busy)
            HStack {
                Button("Back to History", action: model.discardReview).disabled(model.busy)
                Spacer()
                Button("Move and Leave Link", action: model.confirmMove)
                    .buttonStyle(StorageButtonStyle(prominent: true)).disabled(!acknowledged || model.busy)
            }
        }
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.records.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No moved items yet", systemImage: "externaldrive.badge.plus").font(.headline)
                        Text("Right-click a scanned file or folder and choose “Move to Another Drive…” to review a destination.")
                            .font(.callout).foregroundStyle(Tints.secondaryText)
                    }.padding(.vertical, 20)
                }
                ForEach(model.records) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.plan.source.lastPathComponent).font(.headline)
                            Spacer()
                            Text(phase(record)).font(.caption).foregroundStyle(record.phase == .completed ? Tints.mint : Tints.secondaryText)
                        }
                        path("Original", record.plan.source)
                        path("Destination", record.plan.destination)
                        if let message = record.message { Text(message).font(.caption).foregroundStyle(Tints.yellow).textSelection(.enabled) }
                        HStack {
                            Button("Reveal Destination") { model.reveal(record.plan.destination) }
                            if record.phase != .restored {
                                Button(record.phase == .completed ? "Restore…" : "Recover / Restore…") { restoreReview = record }
                                    .disabled(model.busy)
                            }
                            Menu("Recovery Paths") {
                                ForEach(record.recoveryPaths, id: \.path) { url in
                                    Button(url.lastPathComponent) { model.reveal(url) }
                                }
                            }
                        }.font(.caption)
                    }
                    Divider().overlay(Tints.secondaryText.opacity(0.2))
                }
            }
        }.frame(maxHeight: 440)
    }
    private func path(_ label: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Tints.secondaryText)
            Text(StorageLabels.location(url.path)).font(.callout).textSelection(.enabled)
                .lineLimit(3).truncationMode(.middle)
        }
    }
    private func phase(_ record: EasyMoveRecord) -> String {
        switch record.phase {
        case .completed: "Linked"
        case .restored: "Restored"
        default: "Recovery available"
        }
    }
}
