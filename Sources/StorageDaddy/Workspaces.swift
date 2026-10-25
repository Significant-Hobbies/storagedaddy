import SwiftUI
import SaaSMakerUI
import DiskCore
import AppKit
import Charts

struct ApplicationsView: View {
    @EnvironmentObject var m: ExplorerModel
    @ObservedObject var applications: InstalledApplicationsModel
    @State private var searchText = ""
    @AppStorage("applicationsGroupByCategory") private var groupByCategory = true
    @State private var collapsedCategories: Set<String> = []

    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var appGroups: [(category: String, apps: [InstalledApplication])] {
        let rows = visibleApps
        guard groupByCategory else { return [("", rows)] }
        let groups = Dictionary(grouping: rows, by: \.category)
        return groups.keys.sorted { lhs, rhs in
            if (lhs == "Uncategorized") != (rhs == "Uncategorized") { return rhs == "Uncategorized" }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, groups[$0] ?? []) }
    }

    private var visibleApps: [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications.sortedApps }
        return applications.sortedApps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.url.path.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SMSectionHeader("Applications", size: 28).accessibilityLabel("Applications")
                DoodleArt(topic: .applications).frame(width: 72, height: 72)
                Spacer()
                if applications.loading { Button("cancel", action: applications.cancel).accessibilityLabel("Cancel") }
                Button("refresh", action: applications.refresh).accessibilityLabel("Refresh").disabled(applications.loading || applications.removalBusy)
            }
            Text("Apps are discovered automatically in Applications, your personal Applications folder, and macOS app folders. Bundle sizes load in the background; support data is excluded. Use Scan Folder for apps stored elsewhere.").foregroundStyle(Tints.secondaryText)
            applicationSummary
            if let notice = applications.removalNotice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(Tints.mint)
            }
            if applications.removalReview == nil, let error = applications.removalError {
                Text(error).font(.callout).foregroundStyle(Tints.yellow)
            }
            if applications.preparingRemovalID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking the app before removal…").font(.callout)
                    Button("cancel", action: applications.cancelRemoval).accessibilityLabel("Cancel")
                }
            }
            if !applications.status.isEmpty {
                Text(applications.status).font(.caption).foregroundStyle(Tints.secondaryText)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tints.secondaryText)
                TextField("Search apps or categories", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search applications by name, path or category")
                Toggle("Group by category", isOn: $groupByCategory)
                    .toggleStyle(.checkbox).tint(Tints.mint).font(.caption).fixedSize()
                    .help("Group installed apps by category. Turn off to compare all apps in one list.")
                if !searchText.isEmpty {
                    Button("clear") { searchText = "" }.accessibilityLabel("Clear")
                        .buttonStyle(StorageButtonStyle())
                        .accessibilityLabel("Clear application search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tints.mint.opacity(0.28)))
            if applications.loading && applications.apps.isEmpty {
                StorageEmptyView("Finding installed apps…", systemImage: "app.dashed", description: Text("Reading app locations without scanning the selected folder."))
            } else if applications.apps.isEmpty {
                StorageEmptyView("No installed apps found", systemImage: "app.dashed", description: Text("Refresh to search standard application folders."))
            } else if visibleApps.isEmpty {
                StorageEmptyView("No matching applications", systemImage: "magnifyingglass", description: Text("Try a different name, path or category, or clear the search to show all installed apps."))
                Button("clear search") { searchText = "" }.accessibilityLabel("Clear search").buttonStyle(StorageButtonStyle(prominent: true))
            } else {
                applicationColumnHeader
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appGroups, id: \.category) { group in
                            if groupByCategory { categoryHeader(group.category, count: group.apps.count) }
                            if !groupByCategory || searching || !collapsedCategories.contains(group.category) {
                        ForEach(group.apps, id: \.id) { app in
                    let removalBlock = applications.removalBlockReason(for: app)
                    HStack(spacing: 12) {
                        InstalledAppIcon(data: app.iconPNG).frame(width: 40, height: 40).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).fontWeight(.medium).lineLimit(1)
                            Text(StorageLabels.location(app.url.path)).help(app.url.path).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if let date = app.lastUsed {
                                Text(date, format: .dateTime.day().month(.abbreviated).year()).font(.callout)
                                    .help(date.formatted(date: .complete, time: .shortened))
                            } else {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("Unknown").font(.callout)
                                    Text("macOS metadata").font(.caption2)
                                }
                                .foregroundStyle(Tints.secondaryText)
                                .accessibilityLabel("Last used unknown because macOS metadata is unavailable")
                            }
                        }.frame(width: 110, alignment: .trailing)
                            .help("Last use recorded by macOS. It can be missing or outdated; Unknown does not mean never used.")
                        Group {
                        if let allocatedBytes = app.allocatedBytes {
                            Text(DiskFormat.bytes(allocatedBytes)).monospacedDigit()
                        } else if app.sizeUnavailable {
                            Text("Unavailable").font(.caption).foregroundStyle(Tints.secondaryText)
                        } else {
                            Text("Pending…").font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        }.frame(width: 96, alignment: .trailing)
                        Button("analyze") { m.openStorage(.explore); m.start(app.url) }.accessibilityLabel("Analyze")
                            .buttonStyle(StorageButtonStyle())
                            .frame(width: 80)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(StorageButtonStyle())
                            .frame(width: 32)
                            .help("Reveal in Finder")
                            .accessibilityLabel("Reveal \(app.name) in Finder")
                        Button { applications.reviewRemoval(of: app) } label: {
                            Image(systemName: removalBlock == nil ? "trash" : "lock")
                        }
                        .buttonStyle(StorageButtonStyle())
                        .frame(width: 32)
                        .disabled(applications.removalBusy || m.busy || m.monitoring || removalBlock != nil)
                        .help(removalBlock ?? "Review and remove \(app.name)…")
                        .accessibilityLabel("Remove \(app.name)")
                    }
                    .contextMenu {
                        Button("Remove \(app.name)…") { applications.reviewRemoval(of: app) }
                            .disabled(applications.removalBusy || m.busy || m.monitoring || removalBlock != nil)
                        Button("reveal in finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }.accessibilityLabel("Reveal in Finder")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .overlay(alignment: .bottom) { Divider().overlay(Tints.mint.opacity(0.15)) }
                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(AppColors.canvas)
        .buttonStyle(StorageButtonStyle())
        .task { await applications.loadIfNeeded() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            applications.objectWillChange.send()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            applications.objectWillChange.send()
        }
        .sheet(item: $applications.removalReview) { review in
            ApplicationRemovalSheet(review: review, applications: applications) { removedURL in
                if let root = m.scan?.rootPath,
                   removedURL.path.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
                   !m.cleanupRefreshPaths.contains(root) {
                    m.cleanupRefreshPaths.append(root)
                }
            }
        }
    }

    private func categoryHeader(_ category: String, count: Int) -> some View {
        let expanded = searching || !collapsedCategories.contains(category)
        return Button {
            if expanded { collapsedCategories.insert(category) }
            else { collapsedCategories.remove(category) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                Text(category).font(.callout.weight(.semibold))
                Text("\(count)").font(.caption).foregroundStyle(Tints.secondaryText)
                Spacer()
            }
            .foregroundStyle(Tints.secondaryText)
            .padding(.horizontal, 4).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .accessibilityLabel("\(category), \(count) apps")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .help(searching ? "Matching apps are expanded during search." : "Click to \(expanded ? "collapse" : "expand") this category. Categories come from app metadata.")
    }

    private var applicationSummary: some View {
        ViewThatFits(in: .horizontal) {
            summaryMetrics(horizontal: true)
            summaryMetrics(horizontal: false)
        }
    }

    @ViewBuilder private func summaryMetrics(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
        layout {
            Label("\(applications.apps.count) installed", systemImage: "app.fill")
            if horizontal { Divider().frame(height: 14).overlay(Tints.mint.opacity(0.35)) }
            if applications.measuredCount == 0 {
                Label("No bundle sizes measured", systemImage: "externaldrive.badge.questionmark")
            } else {
                Label("\(DiskFormat.bytes(applications.measuredBundleBytes)) from \(applications.measuredCount) measured bundles", systemImage: "externaldrive.fill")
            }
            if applications.pendingCount > 0 {
                Text("\(applications.pendingCount) pending").foregroundStyle(Tints.secondaryText)
            }
            if applications.unavailableCount > 0 {
                Text("\(applications.unavailableCount) unavailable").foregroundStyle(Tints.secondaryText)
            }
            Text("Support data excluded").foregroundStyle(Tints.secondaryText)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sortHeader(_ title: String, sort: ApplicationSort, alignment: Alignment = .trailing) -> some View {
        let active = applications.sort == sort
        return Button {
            if active {
                applications.ascending.toggle()
            } else {
                applications.ascending = sort == .name
                applications.sort = sort
            }
        } label: {
            HStack(spacing: 4) {
                Text(title.lowercased()).accessibilityLabel(title)
                Image(systemName: active && applications.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(active ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Tints.mint : Tints.secondaryText)
        .help(active ? "\(applications.orderLabel). Click to reverse. When grouped, sorting applies within each category. Unknown values stay last." : "Sort by \(sort.rawValue.lowercased()). Unknown values stay last.")
        .accessibilityLabel("Sort by \(sort.rawValue.lowercased())")
        .accessibilityValue(active ? applications.orderLabel : "Not sorted")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var applicationColumnHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 40, height: 1)
            sortHeader("APPLICATION", sort: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("LAST USED", sort: .lastUsed).frame(width: 110, alignment: .trailing)
            sortHeader("BUNDLE SIZE", sort: .size).frame(width: 96, alignment: .trailing)
            Color.clear.frame(width: 168, height: 1)
        }
        .frame(height: 28)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Tints.secondaryText)
        .padding(.horizontal, 4)
    }
}

private struct InstalledAppIcon: View {
    let data: Data?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(Tints.electricBlue).padding(6) }
        }.task(id: data) { image = data.flatMap(NSImage.init(data:)) }
    }
}

struct CleanupView: View {
    @EnvironmentObject var m: ExplorerModel
    var body: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack { SMSectionHeader("Quick Cleanup", size: 28).accessibilityLabel("Quick Cleanup"); DoodleArt(topic: .cleanup).frame(width: 72, height: 72); Spacer(); if m.showCleanup { Button("done") { m.showCleanup = false }.accessibilityLabel("Done") } }
            Text(m.staged.isEmpty ? "Pick caches, dependencies and builds to clean up." : "Review your folders and choose how to clean up. Items with issues are kept.").foregroundStyle(Tints.secondaryText)
            if !m.showCleanup && m.staged.isEmpty { TrashInventoryView() }
            if let scan = m.scan, !m.easyCleanupIDs.isEmpty {
                AutoCleanerCard(scan: scan)
            }
            if let scan = m.scan, !m.quickCleanupFailures.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Kept or skipped").font(.headline)
                    ForEach(m.quickCleanupFailures.keys.sorted(), id: \.self) { id in
                        if scan.nodes.indices.contains(id), let reason = m.quickCleanupFailures[id] {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(StorageLabels.location(scan.url(for: id).path)).font(.callout).help(scan.url(for: id).path)
                                    Text(reason).font(.caption).foregroundStyle(Tints.yellow).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button("inspect") { m.openStorage(.explore); m.open(scan.nodes[id]) }.accessibilityLabel("Inspect kept item")
                            }
                        }
                    }
                }.padding(16).storagePanel()
            }
            if m.staged.isEmpty, m.lastPermanentlyDeletedCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Label("\(m.lastPermanentlyDeletedCount) permanently deleted", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(Tints.mint)
                    Text("These folders bypassed Trash. Refresh to see current storage totals.").foregroundStyle(Tints.secondaryText)
                    Button("refresh scan results", action: m.rescan).accessibilityLabel("Refresh scan results").buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.busy)
                }.padding(16).storagePanel()
            }
            if m.staged.isEmpty, !m.lastTrashedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Moved to Trash", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(Tints.mint)
                    Text("You can review or restore these items from Trash. Trash still uses disk space until emptied.").foregroundStyle(Tints.secondaryText)
                    HStack {
                        Button("show in trash") { NSWorkspace.shared.activateFileViewerSelecting(m.lastTrashedURLs) }.accessibilityLabel("Show in Trash")
                        Button("refresh scan results", action: m.rescan).accessibilityLabel("Refresh scan results").buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.busy)
                    }
                }.padding(.vertical, 24)
                Spacer()
            } else if m.staged.isEmpty && m.lastPermanentlyDeletedCount == 0 {
                if m.easyCleanupIDs.isEmpty {
                    StorageEmptyView("No rebuildable items found in this scan", systemImage: "tray", description: Text("Scan another folder, or add an item from Storage for individual review."))
                }
            }
            else if !m.staged.isEmpty, let scan = m.scan {
                RemovalMeasurementView(scan: scan, ids: m.staged.sorted()).id("\(scan.started):\(m.staged.sorted())")
                LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(m.staged.sorted(), id: \.self) { id in
                    HStack(alignment: .top) {
                        Image(systemName: scan.nodes[id].isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(Tints.forNode(scan.nodes[id])).font(.title3).frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(StorageLabels.name(scan.nodes[id]))
                            if ChromeSigningClones.location(path: scan.url(for: id).path) != nil {
                                Label("Signing copy · Quit Chrome first", systemImage: "square.on.square").font(.caption).foregroundStyle(Tints.yellow)
                            } else if m.quickCleanupCandidateIDs.contains(id) {
                                Label("Rebuildable · Downloads or rebuilds may be needed", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(Tints.mint)
                            } else { CleanupFlag(category: m.cleanupCategory(id)) }
                            Text(StorageLabels.location(scan.url(for: id).path)).help(scan.url(for: id).path).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                            if m.permanentCleanupIDs.contains(id) {
                                Label("Permanently delete · Bypasses Trash", systemImage: "trash.slash").font(.caption).foregroundStyle(Tints.coral)
                            }
                            if let note = CleanupGuidance.chromeCacheNote(path: scan.url(for: id).path) {
                                Text(note).font(.caption).foregroundStyle(Tints.yellow)
                            }
                            if ChromeSigningClones.location(path: scan.url(for: id).path) != nil {
                                Text(ChromeSigningClones.cleanupExplanation).font(.caption).foregroundStyle(Tints.yellow)
                            }
                            if !CleanupGuidance.isProjectDependencies(path: scan.url(for: id).path) {
                                StorageAllocationDetailsView(node: scan.nodes[id])
                            }
                            if let review = m.incompleteCleanup[id] {
                                Label("Added anyway · \(review.skipped) \(review.skipped == 1 ? "item" : "items") not checked", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Tints.coral)
                                Button("review warning") { m.reviewIncompleteCleanup(id) }.accessibilityLabel("Review warning").font(.caption).disabled(m.busy)
                            }
                            if scan.nodes[id].isDirectory && !CleanupGuidance.isProjectDependencies(path: scan.url(for: id).path) {
                                FolderSymlinksView(scan: scan, folderID: id, cleanupReview: true)
                                    .id("\(scan.started.timeIntervalSince1970):\(scan.rootPath):\(id)")
                                    .frame(maxWidth: 540, alignment: .leading)
                            }
                        }
                        Spacer()
                        Text(scan.nodes[id].allocatedBytes == 0 && (m.allocationSummary(scan.nodes[id])?.sharedFiles ?? 0) > 0 ? "Shared" : DiskFormat.bytes(scan.nodes[id].allocatedBytes)).monospacedDigit()
                            .foregroundStyle(Tints.forNode(scan.nodes[id])).frame(width: 104, alignment: .trailing)
                        Button("remove") { m.unstage(id) }.accessibilityLabel("Remove").disabled(m.busy)
                    }.accessibilityElement(children: .contain)
                    Divider()
                }
                }
                if m.staged.contains(where: { scan.nodes.indices.contains($0) && scan.nodes[$0].isDirectory && m.incompleteCleanup[$0] == nil && CleanupGuidance.canDeletePermanently(path: scan.url(for: $0).path) }) {
                    Toggle("Delete Node dependencies and package caches permanently", isOn: $m.deleteNodeCachesPermanently).disabled(m.busy)
                    Text("Bypasses Trash. Local changes in these folders cannot be restored.").font(.caption).foregroundStyle(Tints.secondaryText)
                }
                HStack(alignment: .top) {
                    Text("\(m.staged.count) \(m.staged.count == 1 ? "item" : "items") · \(m.stagedExclusiveBytes.map(DiskFormat.bytes) ?? "Unknown") exclusive allocation").fontWeight(.medium)
                    Spacer()
                    Button(m.permanentCleanupIDs.isEmpty ? "move to trash…" : "clean up…", action: m.trashStaged)
                        .accessibilityLabel(m.permanentCleanupIDs.isEmpty ? "Move to Trash…" : "Clean Up…")
                        .buttonStyle(StorageButtonStyle(prominent: true)).tint(Tints.coral).disabled(m.busy || m.monitoring)
                }
                Text(m.permanentCleanupIDs.isEmpty ? "Trash still uses disk space until it is emptied." : "\(m.permanentCleanupIDs.count) to delete permanently · \(m.staged.count - m.permanentCleanupIDs.count) to Trash after confirmation.").font(.caption).foregroundStyle(Tints.secondaryText)
                if m.monitoring { Text("Stop monitoring before cleanup.").font(.caption).foregroundStyle(Tints.secondaryText) }
            }
        }.padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.background(AppColors.canvas).buttonStyle(StorageButtonStyle())
    }
}

/// Auto Cleaner card: stale, usually-regenerable folders surfaced for review.
/// Suggestions never delete anything — each one stages through the same
/// preflight and review list as a manual pick.
private struct AutoCleanerCard: View {
    let scan: ScanResult
    @EnvironmentObject var m: ExplorerModel
    private var suggestions: [Int] { Array(m.easyCleanupIDs.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("Rebuildable items").font(.headline); Spacer(); summary }
                VStack(alignment: .leading) { Text("Rebuildable items").font(.headline); summary }
            }
            Text("Caches, project dependencies and build outputs. Apps may need to download or rebuild them afterward. Nothing moves automatically.")
                .font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            Button("Review \(m.easyCleanupIDs.count) \(m.easyCleanupIDs.count == 1 ? "item" : "items") (\(DiskFormat.bytes(m.easyCleanupBytes)))…", action: m.stageEasyCleanup)
                .buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.busy || m.monitoring)
            ForEach(suggestions, id: \.self) { id in
                let category = m.cleanupCategory(id) ?? .packageCaches
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol).foregroundStyle(category.color).frame(width: 20)
                        Text(StorageLabels.name(scan.nodes[id])).fontWeight(.medium)
                        Spacer()
                        Text(DiskFormat.bytes(scan.nodes[id].allocatedBytes)).monospacedDigit()
                    }
                    Text(StorageLabels.location(scan.url(for: id).path)).font(.caption)
                        .foregroundStyle(Tints.secondaryText).lineLimit(2).help(scan.url(for: id).path)
                    HStack {
                        Text(category.title).font(.caption).foregroundStyle(Tints.secondaryText)
                        Spacer()
                        Button("inspect") { m.showCleanup = false; m.openStorage(.explore); m.open(scan.nodes[id]) }
                            .accessibilityLabel("Inspect").font(.caption)
                        Button("add for review") { m.stage(id) }.accessibilityLabel("Add for Review").font(.caption).disabled(m.busy)
                    }
                    Divider()
                }
            }
            if m.easyCleanupIDs.count > suggestions.count {
                Text("+ \(m.easyCleanupIDs.count - suggestions.count) more included in Review items")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }.padding(16).storagePanel()
    }
    private var summary: some View {
        Text("\(m.easyCleanupIDs.count) \(m.easyCleanupIDs.count == 1 ? "folder" : "folders") · \(DiskFormat.bytes(m.easyCleanupBytes))")
            .font(.caption).foregroundStyle(Tints.secondaryText)
    }
}
