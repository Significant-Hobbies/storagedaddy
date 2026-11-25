import DiskCore
import SaaSMakerUI
import SwiftUI

struct DeveloperCleanupView: View {
    @EnvironmentObject private var model: ExplorerModel
    @StateObject private var worktreeReview = GitWorktreeReviewModel()
    @State private var worktreesExpanded = true
    @State private var presentedOutcome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SMWorkspaceHeader(model.spaceTarget == nil ? "Developer Cleanup" : "Review cleanup", subtitle: subtitle) {
                Button("Other Cleanup", action: model.openQuickCleanup)
                    .disabled(model.busy)
            }
            if let target = model.spaceTarget {
                Text("\(DiskFormat.bytes(target.available)) available on the startup disk")
                    .font(.headline)
                if model.searchingForMoreCleanup {
                    Text("You can clean these items now. Checking more project folders and worktrees…")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                }
                if let plan = model.developerCleanupPlan, !plan.scopes.isEmpty {
                    let unavailable = plan.scopes.filter { $0.error != nil }.count
                    DisclosureGroup(unavailable == 0 ? "Scanned locations (\(plan.scopes.count))" :
                                        "Scan locations · \(unavailable) unavailable") {
                        ForEach(plan.scopes) { scope in
                            Text(StorageLabels.location(scope.path) + (scope.error.map { " · " + $0 } ?? ""))
                                .font(.caption)
                        }
                    }
                }
                if !model.busy && model.developerCleanupOutcome == nil {
                    Button("Other developer folders", action: model.openDeveloperCleanup)
                        .disabled(!model.canStartDeveloperCleanup)
                }
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
            }
            if let error = model.developerCleanupError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow)
            }
            if let plan = model.developerCleanupPlan {
                if model.spaceTarget != nil && model.developerCleanupOutcome == nil {
                    if plan.items.count > 1 {
                        HStack {
                            Button("Select all") { model.setDeveloperCleanupSelection(Set(plan.items.map(\.id)), planID: plan.id) }
                            Button("Deselect all") { model.setDeveloperCleanupSelection([], planID: plan.id) }
                        }.disabled(!model.canEditCleanupReview)
                    }
                    let dependencies = plan.items.filter { $0.path.hasSuffix("/node_modules") }
                    if !dependencies.isEmpty {
                        Text("\(dependencies.count) idle node_modules installs · \(bytes(dependencies))")
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
                                                model.freezeCleanupReview()
                                                worktreeReview.inspect(candidate, explorer: model)
                                            }.disabled(!model.canEditCleanupReview)
                                        }
                                    }
                                }.font(.caption)
                            }.frame(maxHeight: 140)
                        }
                    }
                }
                if model.spaceTarget != nil && !plan.withheld.isEmpty {
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
                if plan.skipped > 0 {
                    Text("\(plan.skipped.formatted()) locations skipped. Excluded, protected and unreadable locations stay untouched.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }
                if !plan.items.isEmpty, model.developerCleanupOutcome == nil, model.spaceTarget == nil {
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
                    StorageEmptyView(reason == nil ? (model.spaceTarget == nil ? "No supported developer folders found" : "No eligible caches or dependencies found") : "Scan location unavailable",
                        systemImage: "folder", description:
                            Text(reason ?? (model.spaceTarget == nil ? "Add the locations that hold your projects, linked worktrees, or developer caches." : "Review other developer folders to look for more space.")))
                } else {
                    if model.developerCleanupOutcome == nil && model.spaceTarget == nil { selectionControls(plan) }
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
            } else if model.spaceTarget != nil {
                Button("Return to dashboard") { model.workspace = .dashboard }
            } else {
                StorageEmptyView("Choose where to look", systemImage: "folder.badge.gearshape",
                    description: Text("Add project and worktree locations, including any worktrees stored outside your projects folder."))
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
        .onDisappear {
            if presentedOutcome { model.finishViewingDeveloperCleanupResult() }
        }
    }

    private var subtitle: String {
        if model.spaceTarget != nil { return "Tool caches, build caches and project dependencies · startup disk only" }
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
        let isWorktree = model.developerCleanupPlan?.scopes[item.id.scope].worktree != nil
        let name: String
        if isWorktree { name = "Merged worktree · " + url.lastPathComponent }
        else if let cache { name = cache.tool == .go ? "Go build cache" : "\(cache.tool.title) package cache" }
        else if model.spaceTarget != nil {
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
                if let cache { Text(cache.tool.command).font(.caption.monospaced()).foregroundStyle(Tints.secondaryText) }
                if let reason { Text(reason).font(.caption).foregroundStyle(Tints.yellow) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(DiskFormat.bytes(item.allocatedBytes)).monospacedDigit()
                if reason != nil { Text(cache != nil && outcome != nil ? "Check result" : "Kept").foregroundStyle(Tints.yellow).font(.caption) }
                else if let outcome {
                    Text(outcome.deleted.contains(item.id) ? "Deleted" : outcome.trashed.contains(item.id) ? "In Trash" : "Unchanged")
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
        let countLabel = model.spaceTarget != nil ? (count == 1 ? "1 Item" : "\(count) Items") :
            (count == 1 ? "1 Folder" : "\(count) Folders")
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count) selected · \(allocation) on disk").font(.callout.weight(.semibold))
                if model.spaceTarget != nil {
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
            Text("\(outcome.deleted.count) deleted · \(outcome.trashed.count) moved to Trash · \(outcome.kept.count) did not complete")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if model.spaceTarget != nil {
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
