import DiskCore
import SaaSMakerUI
import SwiftUI

struct DeveloperCleanupView: View {
    @EnvironmentObject private var model: ExplorerModel
    @StateObject private var worktreeReview = GitWorktreeReviewModel()
    @State private var worktreesExpanded = false
    @State private var inventory: LargeStorageEntry.Inventory?
    @State private var measuringLargeItems = false
    @State private var trashedPaths = Set<String>()
    @State private var searchDetails = false
    @State private var fileOutcome: String?
    @State private var presentedOutcome = false
    @State private var showingLargeItems = false
    @State private var startWithCodex = false
    @State private var capacityAfterLargeReview: StartupCapacity?
    @State private var resumeAfterLargeReview = false
    @State private var inspectAfterDismissal: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SMWorkspaceHeader(model.isFindingStorageCulprits ? "Storage culprits" : "Developer Cleanup", subtitle: subtitle) {
                Button("Other Cleanup", action: model.openQuickCleanup)
                    .disabled(model.busy)
            }
            if model.isFindingStorageCulprits {
                culpritResults
            } else {
                HStack(spacing: 10) {
                    if !model.developerCleanupFolders.isEmpty {
                        Button("Scan Again", action: model.rescanDeveloperCleanup)
                    }
                    Button(model.developerCleanupFolders.isEmpty ? "Choose Folders…" : "Add Folders…",
                           action: model.chooseDeveloperCleanupFolder)
                        .buttonStyle(SMMacButtonStyle(model.developerCleanupFolders.isEmpty ? .primary : .secondary))
                }.disabled(!model.canStartDeveloperCleanup)

                if !model.developerCleanupFolders.isEmpty {
                    let unavailable = model.developerCleanupPlan?.scopes.filter { $0.error != nil }.count ?? 0
                    DisclosureGroup(unavailable == 0 ? "Scan locations" : "Scan locations · \(unavailable) unavailable") {
                        ForEach(model.developerCleanupFolders, id: \.self) { path in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(StorageLabels.location(path)).lineLimit(1).truncationMode(.middle).help(path)
                                    if let reason = model.developerCleanupPlan?.scopes.first(where: { $0.path == path })?.error {
                                        Text(reason).font(.caption).foregroundStyle(Tints.yellow)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button("Remove") { model.removeDeveloperCleanupFolder(path) }
                                    .accessibilityLabel("Remove \(path) from scan locations")
                                    .disabled(!model.canStartDeveloperCleanup)
                            }.padding(.top, 5)
                        }
                    }
                }
                if let error = model.developerCleanupError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow)
                }
                if let plan = model.developerCleanupPlan {
                    if plan.skipped > 0 {
                        Text("\(plan.skipped.formatted()) locations skipped. Excluded, protected and unreadable locations stay untouched.")
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                    if !plan.items.isEmpty, model.developerCleanupOutcome == nil {
                        let ready = plan.items.filter { $0.keptReason == nil }
                        let kept = plan.items.filter { $0.keptReason != nil }
                        Text("\(ready.count.formatted()) ready · \(bytes(ready))  |  \(kept.count.formatted()) kept · \(bytes(kept))")
                            .font(.callout.weight(.semibold))
                            .help("These are measured folder allocations. Shared blocks and items sent to Trash can reduce the space actually reclaimed.")
                    }
                    if let outcome = model.developerCleanupOutcome {
                        result(outcome).onAppear { presentedOutcome = true }
                    }
                    if plan.items.isEmpty {
                        let reason = plan.scopes.allSatisfy { $0.error != nil } ? plan.scopes.first?.error : nil
                        StorageEmptyView(reason == nil ? "No supported developer folders found" : "Scan location unavailable",
                            systemImage: "folder", description:
                                Text(reason ?? "Add the locations that hold your projects, linked worktrees, or developer caches."))
                    } else {
                        if model.developerCleanupOutcome == nil { selectionControls(plan) }
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(plan.items) { item in
                                    row(item, planID: plan.id)
                                    Divider().padding(.leading, 16)
                                }
                            }.storagePanel()
                        }
                        if model.developerCleanupOutcome == nil { confirmation(plan) }
                    }
                } else if model.busy {
                    Spacer(minLength: 0)
                } else {
                    StorageEmptyView("Choose where to look", systemImage: "folder.badge.gearshape",
                        description: Text("Add project and worktree locations, including any worktrees stored outside your projects folder."))
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.canvas)
        .buttonStyle(SMMacButtonStyle(.secondary))
        .onChange(of: model.developerCleanupPlan?.id, initial: true) { _, _ in
            presentedOutcome = false
        }
        .sheet(isPresented: $worktreeReview.presented) { GitWorktreeReviewSheet(model: worktreeReview) }
        .sheet(isPresented: $showingLargeItems, onDismiss: {
            model.busy = false
            if let url = inspectAfterDismissal {
                inspectAfterDismissal = nil
                model.start(url)
            } else if resumeAfterLargeReview, let home = model.culpritSearchHome {
                inventory = nil
                model.openSpaceTarget(capacityAfterLargeReview ?? model.spaceTarget, home: home, preservingSelection: true)
            }
        }) {
            LargeStorageReviewSheet(home: model.culpritSearchHome ?? FileManager.default.homeDirectoryForCurrentUser, measured: measuringLargeItems ? nil : inventory, startWithCodex: startWithCodex, onScan: { inspectAfterDismissal = $0 },
                                    onChange: { capacity in
                                        capacityAfterLargeReview = capacity
                                        resumeAfterLargeReview = true
                                        model.dashboard.refresh()
                                    })
                .environmentObject(model)
        }
        .onDisappear {
            if presentedOutcome { model.finishViewingDeveloperCleanupResult() }
        }
    }

    private struct SearchScope: Equatable {
        let searchID: UUID
        let home: URL?
        let exclusions: [String]
        let projects: [String]
        let outcome: Bool
        let showingSheet: Bool
    }

    private enum Culprit: Identifiable {
        case ready(DeveloperCleanupReview.Item), review(LargeStorageEntry)
        var id: String {
            switch self { case .ready(let item): item.path; case .review(let entry): entry.id }
        }
        var bytes: Int64 {
            switch self { case .ready(let item): item.allocatedBytes; case .review(let entry): entry.bytes }
        }
    }

    private func rankedCulprits(plan: DeveloperCleanupReview?) -> [Culprit] {
        let ready = plan?.items ?? []
        let covered = FolderExclusions(paths: ready.map(\.path), resolveAliases: false)
        var knownPaths = Set<String>()
        var rows: [Culprit] = ready.map { .ready($0) }
        for entry in inventory?.entries ?? [] where !trashedPaths.contains(entry.id) && !covered.blocksCleanup(entry.url) && knownPaths.insert(entry.id).inserted {
            rows.append(.review(entry))
        }
        return rows.sorted { a, b in
            if a.bytes == b.bytes { return a.id < b.id }
            return a.bytes > b.bytes
        }
    }

    private var culpritResults: some View {
        let plan = model.developerCleanupPlan
        let scope = SearchScope(searchID: model.culpritSearchID, home: model.culpritSearchHome, exclusions: model.excludedFolders,
                                projects: model.developerCleanupFolders, outcome: model.developerCleanupOutcome != nil,
                                showingSheet: showingLargeItems)
        let ranked = rankedCulprits(plan: plan)
        return VStack(alignment: .leading, spacing: 12) {
            if let error = model.developerCleanupError { Text(error).foregroundStyle(Tints.yellow) }
            if let fileOutcome { Text(fileOutcome).font(.callout) }
            if let outcome = model.developerCleanupOutcome {
                result(outcome).onAppear { presentedOutcome = true }
                HStack { repeatSearch; recoveryButton }
                if let plan {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(plan.items) { item in row(item, planID: plan.id); Divider() }
                        }
                    }
                }
            } else {
                if model.busy || measuringLargeItems || inventory == nil {
                    HStack { ProgressView().controlSize(.small); Text(model.busy ? model.progress : "Checking large files…") }
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let inventory {
                            if !inventory.skippedProtectedRoots.isEmpty {
                                Text("Skipped without Full Disk Access: " + inventory.skippedProtectedRoots.joined(separator: ", ") + ". Choose a folder to scan it directly.")
                                    .font(.caption).foregroundStyle(Tints.yellow).padding(.bottom, 4)
                                Button("Scan a folder…", action: model.chooseFolder)
                                    .disabled(!model.canStartDeveloperCleanup).padding(.bottom, 6)
                            }
                            ForEach(inventory.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(Tints.yellow) }
                        }
                        if let plan, plan.skipped > 0 {
                            Text("\(plan.skipped.formatted()) excluded, protected or unreadable locations skipped.")
                                .font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        ForEach(ranked) { culprit in
                            switch culprit {
                            case .ready(let item):
                                if let plan { row(item, planID: plan.id) }
                            case .review(let entry):
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "eye").foregroundStyle(Tints.secondaryText)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.title).font(.callout.weight(.semibold))
                                        Text(entry.explanation).font(.caption)
                                        Text(StorageLabels.location(entry.url.path)).font(.caption).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text(DiskFormat.bytes(entry.bytes)).monospacedDigit()
                                        if entry.vm != nil {
                                            Button("Review VM…") { openLargeReview(usingCodex: false) }
                                                .disabled(!model.canEditCleanupReview)
                                        } else if entry.ordinaryFile != nil {
                                            Button("Move to Trash") {
                                                Task {
                                                    do {
                                                        try await model.trashLargeFile(entry)
                                                        trashedPaths.insert(entry.id)
                                                        fileOutcome = "\(entry.title) moved to Trash. Empty Trash to reclaim space."
                                                    } catch { fileOutcome = error.localizedDescription }
                                                }
                                            }.disabled(!model.canEditCleanupReview)
                                            .accessibilityLabel("Move " + entry.title + " to Trash")
                                        } else {
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                                        }
                                    }
                                }.padding(.vertical, 10).padding(.horizontal, 16)
                            }
                            Divider()
                        }
                        if ranked.isEmpty && plan != nil && model.developerCleanupError == nil && !model.busy && !measuringLargeItems && inventory != nil {
                            Text("No cleanup candidates or large files found in the checked locations.")
                                .foregroundStyle(Tints.secondaryText).padding(.vertical)
                        }
                        if !model.busy {
                            repeatSearch
                        }
                        DisclosureGroup("Scan details and other locations", isExpanded: $searchDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Checks common project and media folders, user downloads, developer caches and known large items. Protected locations require access. Lists up to 20 personal files of at least 100 MB.")
                                    .font(.caption).foregroundStyle(Tints.secondaryText)
                                if let plan {
                                    ForEach(plan.scopes) { scope in
                                        Text(StorageLabels.location(scope.path) + (scope.error.map { " · " + $0 } ?? "")).font(.caption)
                                    }
                                    worktreeDetails(plan)
                                    if plan.items.count > 1 {
                                        HStack {
                                            Button("Select all") { model.setDeveloperCleanupSelection(Set(plan.items.map(\.id)), planID: plan.id) }
                                            Button("Deselect all") { model.setDeveloperCleanupSelection([], planID: plan.id) }
                                        }.disabled(!model.canEditCleanupReview)
                                    }
                                }
                                recoveryButton
                                Button("Other developer folders", action: model.openDeveloperCleanup)
                                    .disabled(!model.canStartDeveloperCleanup)
                                Button("Find more with Codex…") { openLargeReview(usingCodex: true) }.disabled(!model.canEditCleanupReview)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 8)
                    }
                }
                if let plan, !plan.items.isEmpty { Divider(); confirmation(plan) }
            }
        }.frame(maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.culpritSearchID) { _, _ in
            trashedPaths.removeAll()
            fileOutcome = nil
        }
        .task(id: scope) {
            guard let home = scope.home, !scope.outcome, !scope.showingSheet else { return }
            inventory = nil
            measuringLargeItems = true
            let result = await LargeStorageEntry.inventory(home: home, projectFolders: scope.projects, exclusions: scope.exclusions) { partial in
                if !Task.isCancelled { inventory = partial }
            }
            guard !Task.isCancelled else { return }
            inventory = result
            measuringLargeItems = false
        }
    }

    private var repeatSearch: some View {
        Button("Find storage culprits again") {
            model.openSpaceTarget(model.spaceTargetResult ?? model.spaceTarget,
                                  home: model.culpritSearchHome ?? FileManager.default.homeDirectoryForCurrentUser)
        }.disabled(!model.canStartDeveloperCleanup)
    }

    @ViewBuilder private var recoveryButton: some View {
        let folder = (model.culpritSearchHome ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Library/Application Support/StorageDaddy/Cleanup Recovery")
        if FileManager.default.fileExists(atPath: folder.path) {
            Button("Open Cleanup Recovery") { NSWorkspace.shared.open(folder) }
        }
    }

    @ViewBuilder private func worktreeDetails(_ plan: DeveloperCleanupReview) -> some View {
        let dependencies = plan.items.filter { $0.path.hasSuffix("/node_modules") }
        if plan.projectsMeasured || !dependencies.isEmpty {
            let kept = plan.withheld.filter { $0.item.path.hasSuffix("/node_modules") }.count
            Text("node_modules · \(dependencies.count) ready (\(bytes(dependencies))) · \(kept) kept")
                .font(.callout.weight(.semibold))
        }
        let worktrees = plan.idleWorktrees
        if !worktrees.isEmpty {
            DisclosureGroup("\(worktrees.count) Git \(worktrees.count == 1 ? "worktree" : "worktrees") with no open files detected", isExpanded: $worktreesExpanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(worktrees) { candidate in
                            HStack {
                                Text(StorageLabels.location(candidate.url.path)).lineLimit(1).truncationMode(.middle)
                                    .help(candidate.url.path)
                                if let preview = plan.checkedWorktrees[candidate.url.path] { Text(preview.status).foregroundStyle(Tints.secondaryText) }
                                Spacer()
                                if candidate.allocatedBytes > 0 { Text(DiskFormat.bytes(candidate.allocatedBytes)).monospacedDigit() }
                                Button("Review") {
                                    worktreeReview.inspect(candidate, explorer: model)
                                }.disabled(!model.canEditCleanupReview)
                            }
                        }
                    }.font(.caption)
                }.frame(maxHeight: 140)
            }
        }
        if !plan.withheld.isEmpty {
            DisclosureGroup("\(plan.withheld.count.formatted()) folders and caches kept") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.withheld) { entry in
                            Text(StorageLabels.location(entry.item.path) + (entry.item.allocatedBytes > 0 ? " · " + DiskFormat.bytes(entry.item.allocatedBytes) : ""))
                            Text(entry.reason).foregroundStyle(Tints.secondaryText)
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
        }
    }

    private func openLargeReview(usingCodex: Bool) {
        guard model.storageOperationBlockReason(scheduled: false, allowingDiscovery: true) == nil else { return }
        capacityAfterLargeReview = nil
        resumeAfterLargeReview = model.measuringCulprits
        if resumeAfterLargeReview { model.freezeCleanupReview() }
        model.busy = true
        startWithCodex = usingCodex
        showingLargeItems = true
    }

    private var subtitle: String {
        if model.isFindingStorageCulprits {
            let capacity = model.spaceTarget.map { "\(DiskFormat.bytes($0.available)) available · " } ?? ""
            return capacity + "Largest measured items in the checked locations."
        }
        if let root = model.developerCleanupFolders.first, model.developerCleanupFolders.count == 1 {
            return StorageLabels.location(root)
        }
        return model.developerCleanupFolders.isEmpty ? "Find rebuildable developer files." :
            "Review developer files across \(model.developerCleanupFolders.count) folders."
    }

    private func selectionControls(_ plan: DeveloperCleanupReview) -> some View {
        HStack(spacing: 12) {
            Button("Select All") {
                model.setDeveloperCleanupSelection(Set(plan.items.filter { $0.keptReason == nil }.map(\.id)), planID: plan.id)
            }
            Button("Clear") { model.setDeveloperCleanupSelection([], planID: plan.id) }
            Spacer()
            Toggle("Permanently delete eligible dependencies", isOn: Binding(
                get: { model.developerCleanupDeletesPermanently },
                set: { model.setDeveloperCleanupDeletesPermanently($0, planID: plan.id) }
            ))
        }.disabled(model.busy)
    }

    private func row(_ item: DeveloperCleanupReview.Item, planID: UUID) -> some View {
        let outcome = model.developerCleanupOutcome
        let reason = outcome?.kept[item.id] ?? item.keptReason
        let url = URL(fileURLWithPath: item.path)
        let cache = model.developerCleanupPlan.flatMap { plan in
            plan.id == planID && plan.scopes.indices.contains(item.id.scope) ? plan.scopes[item.id.scope].cache : nil
        }
        let isWorktree = model.developerCleanupPlan.flatMap { plan in
            plan.id == planID && plan.scopes.indices.contains(item.id.scope) ? plan.scopes[item.id.scope].worktree : nil
        } != nil
        let name: String
        if let plan = model.developerCleanupPlan, plan.id == planID, plan.scopes.indices.contains(item.id.scope),
           let generated = plan.scopes[item.id.scope].generated { name = generated.title }
        else if isWorktree { name = "Merged worktree · " + url.lastPathComponent }
        else if let cache { name = cache.displayName }
        else if model.isFindingStorageCulprits {
            let parent = url.deletingLastPathComponent()
            switch url.lastPathComponent {
            case "Intermediates.noindex": name = parent.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + " · Swift build intermediates"
            case "cache" where parent.lastPathComponent == ".next": name = parent.deletingLastPathComponent().lastPathComponent + " · Next.js cache"
            case "node_modules" where parent.deletingLastPathComponent().lastPathComponent == "_npx": name = "npx tool dependencies · " + parent.lastPathComponent
            default: name = parent.lastPathComponent + " / " + url.lastPathComponent
            }
        } else { name = url.lastPathComponent }
        let deletesPermanently = model.developerCleanupDeletesPermanently && item.canDeletePermanently
        let method = deletesPermanently ? "Delete permanently" : "Move to Trash"
        return HStack(alignment: .top, spacing: 12) {
            if outcome == nil && reason == nil {
                Toggle("Include \(item.path)", isOn: Binding(get: {
                    model.developerCleanupSelectedIDs.contains(item.id)
                }, set: { include in
                    var selected = model.developerCleanupSelectedIDs
                    if include { selected.insert(item.id) }
                    else { selected.remove(item.id) }
                    model.setDeveloperCleanupSelection(selected, planID: planID)
                })).labelsHidden().disabled(!model.canEditCleanupReview)
            } else {
                Image(systemName: reason != nil ? "lock" : "folder")
                    .foregroundStyle(Tints.secondaryText).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.callout.weight(.semibold))
                Text(StorageLabels.location(item.path)).font(.caption).foregroundStyle(Tints.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(item.path)
                if let recovery = item.recoveryPath {
                    Text("\(item.verifiedPackages) lockfile-listed packages · Remaining files move to Cleanup Recovery")
                        .font(.caption).foregroundStyle(Tints.secondaryText).help(recovery)
                    if outcome != nil && FileManager.default.fileExists(atPath: recovery + "/node_modules") {
                        Button("Show retained files") { NSWorkspace.shared.open(URL(fileURLWithPath: recovery)) }
                    }
                }
                if let cache, cache.tool == .pnpm || cache.tool == .lume {
                    Text(cache.tool.consequence).font(.caption).foregroundStyle(Tints.secondaryText)
                }
                if let cache { Text(cache.tool.command).font(.caption.monospaced()).foregroundStyle(Tints.secondaryText) }
                if let reason { Text(reason).font(.caption).foregroundStyle(Tints.yellow) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(DiskFormat.bytes(item.allocatedBytes)).monospacedDigit()
                if reason != nil { Text((cache != nil || item.recoveryPath != nil) && outcome != nil ? "Check result" : "Kept").foregroundStyle(Tints.yellow).font(.caption) }
                else if let outcome {
                    Text(outcome.deleted.contains(item.id) ? (item.recoveryPath == nil ? "Deleted" : "Packages cleaned") : outcome.trashed.contains(item.id) ? "In Trash" : "Unchanged")
                        .foregroundStyle(Tints.secondaryText).font(.caption)
                } else {
                    Text(method).foregroundStyle(deletesPermanently ? Tints.coral : Tints.secondaryText).font(.caption)
                }
            }
        }.padding(.vertical, 10).padding(.horizontal, 16)
    }

    private func bytes(_ items: [DeveloperCleanupReview.Item]) -> String {
        DiskFormat.bytes(items.reduce(0) { $0 + $1.allocatedBytes })
    }

    private func confirmation(_ plan: DeveloperCleanupReview) -> some View {
        let selected = model.developerCleanupSelectedIDs
        let items = plan.items.filter { selected.contains($0.id) }
        let permanently = model.developerCleanupDeletesPermanently
        let permanentCount = permanently ? items.filter(\.canDeletePermanently).count : 0
        let count = items.count
        let allocation = bytes(items)
        let countLabel = model.isFindingStorageCulprits ? (count == 1 ? "1 Item" : "\(count) Items") :
            (count == 1 ? "1 Folder" : "\(count) Folders")
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count) selected · \(allocation) on disk").font(.callout.weight(.semibold))
                if model.isFindingStorageCulprits {
                    Text("Deletes selected checkouts, dependencies and caches permanently. Merged worktree history stays in Git.")
                } else if permanentCount > 0 {
                    Text("\(permanentCount) permanent · \(count - permanentCount) to Trash. Permanent deletion cannot be undone.")
                } else {
                    Text("Items in Trash use disk space until you empty it.")
                }
            }.font(.caption).foregroundStyle(Tints.secondaryText)
            Spacer(minLength: 8)
            Button(permanentCount == 0 ? "Move \(countLabel) to Trash" : permanentCount == count ? "Delete \(countLabel) Permanently" : "Clean Up \(countLabel)") {
                model.confirmDeveloperCleanup(planID: plan.id, ids: selected, permanently: permanently)
            }.buttonStyle(SMMacButtonStyle(.primary))
                .disabled(count == 0 || !model.canEditCleanupReview)
        }
    }

    private func result(_ outcome: DeveloperCleanupReview.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(outcome.cancelled ? "Cleanup stopped" : "Cleanup complete").font(.headline)
            Text("\(outcome.deleted.count) cleaned permanently · \(outcome.trashed.count) moved to Trash · \(outcome.kept.count) did not complete")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if model.isFindingStorageCulprits {
                if let capacity = model.spaceTargetResult {
                    if let before = model.capacityBeforeCleanup, before.total == capacity.total {
                        let delta = capacity.available - before.available
                        Text(delta >= 0 ? "Available space increased by \(DiskFormat.bytes(delta))." :
                                "Available space decreased by \(DiskFormat.bytes(-delta)) during cleanup.")
                    }
                    Text("\(DiskFormat.bytes(capacity.available)) available now · \(capacity.usedPercent)% used")
                } else {
                    Text("Current startup disk usage is unavailable.")
                }
            }
            if !outcome.trashed.isEmpty {
                Text("Review and empty Trash in Finder when you’re ready to reclaim that space.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
    }
}
