import DiskCore
import SaaSMakerUI
import SwiftUI

struct DeveloperCleanupView: View {
    @EnvironmentObject private var model: ExplorerModel
    @State private var selected: Set<Int> = []
    @State private var permanently = true
    @State private var presentedOutcome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SMWorkspaceHeader("Developer Cleanup", subtitle: subtitle) {
                Button("Other Cleanup", action: model.openQuickCleanup)
                    .disabled(model.busy)
            }
            HStack(spacing: 10) {
                if let folder = model.developerCleanupFolder {
                    Button("Scan Again") { model.findDeveloperCleanup(in: URL(fileURLWithPath: folder)) }
                }
                Button(model.developerCleanupFolder == nil ? "Choose Projects Folder…" : "Change Folder…",
                       action: model.chooseDeveloperCleanupFolder)
                    .buttonStyle(SMMacButtonStyle(model.developerCleanupFolder == nil ? .primary : .secondary))
            }.disabled(!model.canStartDeveloperCleanup)

            if let error = model.developerCleanupError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow)
            }
            if let plan = model.developerCleanupPlan {
                if plan.skipped > 0 {
                    Text("\(plan.skipped.formatted()) locations skipped. Excluded, protected and unreadable locations stay untouched.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }
                if let outcome = model.developerCleanupOutcome {
                    result(outcome).onAppear { presentedOutcome = true }
                }
                if plan.items.isEmpty {
                    StorageEmptyView("No supported developer folders found", systemImage: "folder", description:
                        Text("Choose the folder containing your projects to look for Node dependencies, Swift and Rust build outputs, and framework caches."))
                } else {
                    if model.developerCleanupOutcome == nil { selectionControls(plan) }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(plan.items) { item in
                                row(item)
                                Divider().padding(.leading, 16)
                            }
                        }.storagePanel()
                    }
                    if model.developerCleanupOutcome == nil { confirmation(plan) }
                }
            } else if model.busy {
                Spacer(minLength: 0)
            } else {
                StorageEmptyView("Start with your projects folder", systemImage: "folder.badge.gearshape",
                    description: Text("Scan for rebuildable dependencies and build outputs, then confirm the folders you want to remove."))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.canvas)
        .buttonStyle(SMMacButtonStyle(.secondary))
        .onChange(of: model.developerCleanupPlan?.id, initial: true) { _, _ in
            presentedOutcome = false
            selected = Set(model.developerCleanupPlan?.items.filter { $0.keptReason == nil }.map(\.id) ?? [])
        }
        .onDisappear {
            if presentedOutcome { model.finishViewingDeveloperCleanupResult() }
        }
    }

    private var subtitle: String {
        if let root = model.developerCleanupPlan?.rootPath ?? model.developerCleanupFolder {
            return StorageLabels.location(root)
        }
        return "Find dependencies and build outputs inside a projects folder."
    }

    private func selectionControls(_ plan: DeveloperCleanupPlan) -> some View {
        HStack(spacing: 12) {
            Button("Select All") { selected = Set(plan.items.filter { $0.keptReason == nil }.map(\.id)) }
            Button("Clear") { selected.removeAll() }
            Spacer()
            Toggle("Permanently delete eligible dependencies", isOn: $permanently)
        }.disabled(model.busy)
    }

    private func row(_ item: DeveloperCleanupPlan.Item) -> some View {
        let outcome = model.developerCleanupOutcome
        let reason = outcome?.kept[item.id] ?? item.keptReason
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let method = permanently && item.canDeletePermanently ? "Delete permanently" : "Move to Trash"
        return HStack(alignment: .top, spacing: 12) {
            if outcome == nil && reason == nil {
                Toggle("Include \(item.path)", isOn: Binding(get: { selected.contains(item.id) }, set: { include in
                    if include { selected.insert(item.id) }
                    else { selected.remove(item.id) }
                })).labelsHidden().disabled(model.busy)
            } else {
                Image(systemName: reason != nil ? "lock" : "folder")
                    .foregroundStyle(Tints.secondaryText).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.callout.weight(.semibold))
                Text(StorageLabels.location(item.path)).font(.caption).foregroundStyle(Tints.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(item.path)
                if let reason { Text(reason).font(.caption).foregroundStyle(Tints.yellow) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(DiskFormat.bytes(item.allocatedBytes)).monospacedDigit()
                if reason != nil { Text("Kept").foregroundStyle(Tints.yellow).font(.caption) }
                else if let outcome {
                    Text(outcome.deleted.contains(item.id) ? "Deleted" : outcome.trashed.contains(item.id) ? "In Trash" : "Unchanged")
                        .foregroundStyle(Tints.secondaryText).font(.caption)
                } else {
                    Text(method).foregroundStyle(permanently && item.canDeletePermanently ? Tints.coral : Tints.secondaryText).font(.caption)
                }
            }
        }.padding(.vertical, 10).padding(.horizontal, 16)
    }

    private func confirmation(_ plan: DeveloperCleanupPlan) -> some View {
        let items = plan.items.filter { selected.contains($0.id) }
        let permanentCount = permanently ? items.filter(\.canDeletePermanently).count : 0
        let count = items.count
        let allocation = DiskFormat.bytes(items.reduce(0) { $0 + $1.allocatedBytes })
        let countLabel = count == 1 ? "1 Folder" : "\(count) Folders"
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count) selected · \(allocation) allocated").font(.callout.weight(.semibold))
                if permanentCount > 0 {
                    Text("\(permanentCount) permanent · \(count - permanentCount) to Trash. Permanent deletion cannot be undone.")
                } else {
                    Text("Items in Trash use disk space until you empty it.")
                }
            }.font(.caption).foregroundStyle(Tints.secondaryText)
            Spacer(minLength: 8)
            Button(permanentCount == 0 ? "Move \(countLabel) to Trash" : permanentCount == count ? "Delete \(countLabel) Permanently" : "Clean Up \(countLabel)") {
                model.confirmDeveloperCleanup(planID: plan.id, ids: selected, permanently: permanently)
            }.buttonStyle(SMMacButtonStyle(.primary))
                .disabled(count == 0 || !model.canStartDeveloperCleanup)
        }
    }

    private func result(_ outcome: DeveloperCleanupPlan.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(outcome.cancelled ? "Cleanup stopped" : "Cleanup complete").font(.headline)
            Text("\(outcome.deleted.count) deleted · \(outcome.trashed.count) moved to Trash · \(outcome.kept.count) could not be removed")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if !outcome.trashed.isEmpty {
                Text("Review and empty Trash in Finder when you’re ready to reclaim that space.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
    }
}
