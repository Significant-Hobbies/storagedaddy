import AppKit
import DiskCore
import SaaSMakerUI
import SwiftUI

@MainActor
final class GitWorktreeReviewModel: ObservableObject {
    @Published var presented = false
    @Published private(set) var review: GitWorktreeReview?
    @Published private(set) var managed: FleetManagedCheckout.Preview?
    private var refreshOnClose = false
    @Published private(set) var working = false
    @Published private(set) var message: String?
    private let manager = GitWorktreeManager()
    private var task: Task<Void, Never>?
    private weak var explorer: ExplorerModel?

    func inspect(_ candidate: GitWorktreeCandidate, explorer: ExplorerModel) {
        guard !working else { return }
        let interrupted = explorer.searchingForMoreCleanup
        if interrupted { explorer.freezeCleanupReview() }
        guard explorer.storageOperationBlockReason(scheduled: false) == nil else { return }
        self.explorer = explorer; explorer.busy = true
        review = nil; managed = nil; refreshOnClose = interrupted; message = nil; presented = true; working = true
        let exclusions = explorer.excludedFolders
        task = Task {
            do {
                if FleetManagedCheckout.manages(candidate.url) {
                    managed = try await Task.detached(priority: .userInitiated) {
                        try FleetManagedCheckout.inspect(candidate, exclusions: exclusions)
                    }.value
                } else { review = try await manager.inspect(candidate: candidate, excludedFolders: exclusions) }
            }
            catch { message = error.localizedDescription }
            working = false; task = nil
        }
    }
    func remove() {
        guard !working, let explorer, review?.canRemove == true || managed?.eligible == true else { return }
        working = true
        let exclusions = explorer.excludedFolders
        task = Task {
            do {
                if let managed {
                    try await Task.detached(priority: .userInitiated) { try FleetManagedCheckout.remove(managed, exclusions: exclusions) }.value
                } else if let review { try await manager.remove(reviewed: review, excludedFolders: exclusions) }
                refreshOnClose = true
                self.review = nil; self.managed = nil
                message = "Worktree removed. Its branch remains in the repository. Rescan for current totals."
                explorer.progress = message!
            } catch { self.review = nil; self.managed = nil; message = error.localizedDescription }
            working = false; task = nil
        }
    }
    func close() {
        guard !working else { return }
        presented = false; review = nil; managed = nil; explorer?.busy = false
        if refreshOnClose, let explorer, let capacity = explorer.spaceTarget { explorer.openSpaceTarget(capacity) }
        explorer = nil
    }
}

struct GitWorktreeView: View {
    @EnvironmentObject private var m: ExplorerModel
    @StateObject private var reviewModel = GitWorktreeReviewModel()
    @State private var groups: [String: [GitWorktreeCandidate]] = [:]
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SMSectionHeader("Git worktrees", size: 22)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await discover() } }.disabled(loading || m.busy)
            }
            Text("Check linked checkouts in this scan, grouped by repository. Review current changes, upstream and commit reachability before Git removes a worktree.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if let error { Text(error).foregroundStyle(Tints.yellow) }
            if !loading && groups.isEmpty { Text("No Git checkouts found in this scan.").foregroundStyle(Tints.secondaryText) }
            ForEach(groups.keys.sorted(), id: \.self) { common in
                VStack(alignment: .leading, spacing: 8) {
                    Text(StorageLabels.location(common)).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                    ForEach(groups[common] ?? []) { candidate in
                        HStack {
                            Text(candidate.url.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Text(DiskFormat.bytes(candidate.allocatedBytes)).monospacedDigit()
                            Button("Review") { reviewModel.inspect(candidate, explorer: m) }.disabled(m.storageOperationBlockReason(scheduled: false) != nil)
                        }.font(.callout)
                    }
                }.padding(14).storagePanel()
            }
        }
        .task(id: m.scan?.started) { await discover() }
        .sheet(isPresented: $reviewModel.presented) { GitWorktreeReviewSheet(model: reviewModel) }
    }
    private func discover() async {
        guard let scan = m.scan, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let found = try await Task.detached(priority: .utility) {
                let candidates = try GitWorktreeManager.discover(in: scan)
                var grouped: [String: [GitWorktreeCandidate]] = [:]
                for candidate in candidates {
                    try Task.checkCancellation()
                    let common = GitCheckoutProbe.runLocal(at: candidate.url, arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"])?
                        .trimmingCharacters(in: .newlines) ?? "Repository metadata unavailable"
                    grouped[common, default: []].append(candidate)
                }
                return grouped
            }.value
            guard m.scan?.started == scan.started else { return }
            groups = found
        } catch { self.error = error.localizedDescription }
    }
}

struct GitWorktreeReviewSheet: View {
    @ObservedObject var model: GitWorktreeReviewModel
    @State private var acknowledged = false
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Git worktree").font(.title2.weight(.semibold))
            if model.working { ProgressView("Checking Git and current files…") }
            if let managed = model.managed {
                Text(managed.candidate.url.path).font(.callout).textSelection(.enabled)
                Text("Retired Fleet workspace" + (managed.candidate.allocatedBytes > 0 ? " · " + DiskFormat.bytes(managed.candidate.allocatedBytes) : ""))
                if managed.eligible {
                    Text("Fleet verified merged history and checked for leases, changes and unrecognized ignored files.")
                    Toggle("I reviewed this checkout and its generated files", isOn: $acknowledged)
                    Button("Remove Worktree…", role: .destructive) { confirming = true }.disabled(!acknowledged || model.working)
                } else {
                    Text(managed.status).foregroundStyle(Tints.yellow)
                    if !managed.ignoredPaths.isEmpty {
                        DisclosureGroup("Ignored paths kept (\(managed.ignoredPaths.count))") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(managed.ignoredPaths, id: \.self) { Text($0).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 150).font(.caption)
                        }
                    }
                    Button("Show checkout in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([managed.candidate.url])
                    }
                }
            }
            if let review = model.review {
                Text(review.candidate.url.path).font(.callout).textSelection(.enabled)
                LabeledContent("Repository", value: review.commonDirectory.path)
                LabeledContent("Branch", value: review.branch ?? "Detached HEAD")
                LabeledContent("Changes", value: review.changedEntries.map(String.init) ?? "Unknown")
                LabeledContent("Ahead of upstream", value: review.aheadOfUpstream.map(String.init) ?? "Unknown / no upstream")
                LabeledContent("Commits only here", value: review.commitsOnlyHere.map(String.init) ?? "Unknown")
                ForEach(review.removalBlockers, id: \.self) { Text($0).font(.callout).foregroundStyle(Tints.yellow) }
                if review.canRemove {
                    Text("Git permanently removes this checkout and its ignored files. This does not use Trash. The branch stays in the repository; recreating a checkout does not restore ignored files.")
                        .font(.callout).foregroundStyle(Tints.yellow)
                    Toggle("I reviewed this checkout and its ignored files", isOn: $acknowledged)
                    Button("Remove Worktree…", role: .destructive) { confirming = true }.disabled(!acknowledged || model.working)
                }
            }
            if let message = model.message { Text(message).textSelection(.enabled).font(.callout) }
            HStack { Spacer(); Button("Done", action: model.close).disabled(model.working) }
        }.padding(28).frame(width: 620).fixedSize(horizontal: false, vertical: true)
            .background(AppColors.canvas).foregroundStyle(AppColors.ink).buttonStyle(SMMacButtonStyle(.secondary))
            .interactiveDismissDisabled(true)
            .confirmationDialog("Permanently remove this Git worktree?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove Worktree", role: .destructive, action: model.remove)
            } message: { Text("Git status, commit reachability, active use and the exact reviewed files are checked again. No force removal is used.") }
    }
}
