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
                SMSectionHeader("Applications", size: 26).accessibilityLabel("Applications")
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
                        .buttonStyle(SMMacButtonStyle(.secondary))
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
                Button("clear search") { searchText = "" }.accessibilityLabel("Clear search").buttonStyle(SMMacButtonStyle(.primary))
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
                            .buttonStyle(SMMacButtonStyle(.secondary))
                            .frame(width: 80)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(SMMacButtonStyle(.secondary))
                            .frame(width: 32)
                            .help("Reveal in Finder")
                            .accessibilityLabel("Reveal \(app.name) in Finder")
                        Button { applications.reviewRemoval(of: app) } label: {
                            Image(systemName: removalBlock == nil ? "trash" : "lock")
                        }
                        .buttonStyle(SMMacButtonStyle(.secondary))
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
        .padding(28)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(AppColors.canvas)
        .buttonStyle(SMMacButtonStyle(.secondary))
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
    @State private var expandedStorageDetails: Set<Int> = []
    var body: some View {
        // These depend on the selection, not on an individual visible row.
        // In particular, permanentCleanupIDs validates every staged path. Doing
        // that inside ForEach makes scrolling quadratic during cleanup updates.
        let stagedIDs = m.staged.sorted()
        let permanentIDs = m.permanentCleanupIDs
        let quickCandidateIDs = Set(m.quickCleanupCandidateIDs)
        let easyIDs = m.easyCleanupIDs
        GeometryReader { geometry in
        ScrollView {
        // Keep async panels mounted while the rows scroll out of view.
        VStack(alignment: .leading, spacing: 16) {
            SMWorkspaceHeader("Quick Cleanup", subtitle: m.scan == nil ? "Review Trash, or scan a folder to find cleanup candidates." : m.staged.isEmpty ? "Pick caches, dependencies and builds to clean up." : "Review your folders and choose how to clean up. Items with issues are kept.") {
                HStack(spacing: 16) {
                    DoodleArt(topic: .cleanup).frame(width: 72, height: 72)
                    if m.showCleanup { Button("done") { m.showCleanup = false }.accessibilityLabel("Done") }
                }
            }.accessibilityLabel("Quick Cleanup")
            if m.staged.isEmpty, let scan = m.scan, !easyIDs.isEmpty {
                AutoCleanerCard(scan: scan, ids: easyIDs)
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
                    Button("refresh scan results", action: m.rescan).accessibilityLabel("Refresh scan results").buttonStyle(SMMacButtonStyle(.primary)).disabled(m.busy)
                }.padding(16).storagePanel()
            }
            if m.staged.isEmpty, !m.lastTrashedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Moved to Trash", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(Tints.mint)
                    Text("You can review or restore these items from Trash. Trash still uses disk space until emptied.").foregroundStyle(Tints.secondaryText)
                    HStack {
                        Button("show in trash") { NSWorkspace.shared.activateFileViewerSelecting(m.lastTrashedURLs) }.accessibilityLabel("Show in Trash")
                        Button("refresh scan results", action: m.rescan).accessibilityLabel("Refresh scan results").buttonStyle(SMMacButtonStyle(.primary)).disabled(m.busy)
                    }
                }.padding(.vertical, 24)
                Spacer()
            } else if m.staged.isEmpty && m.lastPermanentlyDeletedCount == 0 {
                if easyIDs.isEmpty {
                    StorageEmptyView(m.scan == nil ? "Scan to find rebuildable items" : "No rebuildable items found in this scan", systemImage: "tray", description: Text("Scan a folder, or add an item from Storage for individual review."))
                }
            }
            else if !m.staged.isEmpty, let scan = m.scan {
                RemovalMeasurementView(scan: scan, ids: stagedIDs).id("\(scan.started):\(stagedIDs)")
                SMSettingsGroup {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(stagedIDs, id: \.self) { id in
                            cleanupRow(id: id, scan: scan, permanentIDs: permanentIDs,
                                       quickCandidateIDs: quickCandidateIDs)
                            if id != stagedIDs.last { Divider().padding(.horizontal, 16) }
                        }
                    }
                }
            }
            if !m.staged.isEmpty, let scan = m.scan, !easyIDs.isEmpty {
                DisclosureGroup("More rebuildable items (\(easyIDs.count))") {
                    AutoCleanerCard(scan: scan, ids: easyIDs).padding(.top, 12)
                }
            }
            TrashInventoryView()
        }.padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !stagedIDs.isEmpty { cleanupControls(permanentIDs: permanentIDs) }
        }
        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.background(AppColors.canvas).buttonStyle(SMMacButtonStyle(.secondary))
            .onChange(of: m.scan?.started) { _, _ in expandedStorageDetails = [] }
    }

    private func cleanupRow(id: Int, scan: ScanResult, permanentIDs: Set<Int>, quickCandidateIDs: Set<Int>) -> some View {
        let node = scan.nodes[id]
        let path = scan.url(for: id).path
        let signingCopy = ChromeSigningClones.location(path: path) != nil
        let dependencies = CleanupGuidance.isProjectDependencies(path: path)
        return VStack(alignment: .leading, spacing: 0) {
            SMResourceRow(StorageLabels.name(node), subtitle: StorageLabels.location(path),
                          systemImage: node.isDirectory ? "folder" : "doc") {
                EmptyView()
            } trailing: {
                HStack(spacing: 16) {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(node.allocatedBytes == 0 && (m.allocationSummary(node)?.sharedFiles ?? 0) > 0 ? "Shared" : DiskFormat.bytes(node.allocatedBytes))
                            .font(.custom(DaddyTheme.palette.sansFont, size: 14).weight(.medium)).monospacedDigit()
                        Label(permanentIDs.contains(id) ? "Permanently delete · Bypasses Trash" : "Move to Trash",
                              systemImage: permanentIDs.contains(id) ? "trash.slash" : "trash")
                            .font(.caption).foregroundStyle(permanentIDs.contains(id) ? Tints.coral : Tints.secondaryText)
                    }
                    Button("remove") { m.unstage(id) }.accessibilityLabel("Remove").disabled(m.busy)
                        .buttonStyle(SMMacButtonStyle(.quiet))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if signingCopy {
                    Label("Signing copy · Quit Chrome first", systemImage: "square.on.square").foregroundStyle(Tints.yellow)
                    Text(ChromeSigningClones.cleanupExplanation).foregroundStyle(Tints.yellow)
                } else if quickCandidateIDs.contains(id) {
                    Label("Rebuildable · Downloads or rebuilds may be needed", systemImage: "arrow.clockwise").foregroundStyle(Tints.mint)
                } else { CleanupFlag(category: m.cleanupCategory(id)) }
                if let note = CleanupGuidance.chromeCacheNote(path: path) { Text(note).foregroundStyle(Tints.yellow) }
                if let review = m.incompleteCleanup[id] {
                    Label("Added anyway · \(review.skipped) \(review.skipped == 1 ? "item" : "items") not checked", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tints.coral)
                    Button("review warning") { m.reviewIncompleteCleanup(id) }.accessibilityLabel("Review warning").disabled(m.busy)
                }
                if !dependencies {
                    DisclosureGroup("Storage details", isExpanded: Binding(
                        get: { expandedStorageDetails.contains(id) },
                        set: { if $0 { expandedStorageDetails.insert(id) } else { expandedStorageDetails.remove(id) } }
                    )) {
                        if expandedStorageDetails.contains(id) {
                            VStack(alignment: .leading, spacing: 8) {
                                StorageAllocationDetailsView(node: node)
                                if node.isDirectory {
                                    FolderSymlinksView(scan: scan, folderID: id, cleanupReview: true)
                                        .id("\(scan.started.timeIntervalSince1970):\(scan.rootPath):\(id)")
                                        .frame(maxWidth: 540, alignment: .leading)
                                }
                            }.padding(.top, 6)
                        }
                    }
                }
            }.font(.caption).padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private func cleanupControls(permanentIDs: Set<Int>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let scan = m.scan,
               m.staged.contains(where: { scan.nodes.indices.contains($0) && scan.nodes[$0].isDirectory && m.incompleteCleanup[$0] == nil && CleanupGuidance.canDeletePermanently(path: scan.url(for: $0).path) }) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Delete Node dependencies and package caches permanently", isOn: $m.deleteNodeCachesPermanently).disabled(m.busy)
                    Text("Bypasses Trash. Local changes in these folders cannot be restored.").font(.caption).foregroundStyle(Tints.secondaryText)
                }.padding(.horizontal, 32).padding(.vertical, 12)
            }
            SMSelectionBar("\(m.staged.count) \(m.staged.count == 1 ? "item" : "items") · \(m.stagedExclusiveBytes.map(DiskFormat.bytes) ?? "Unknown") exclusive allocation",
                           detail: m.monitoring ? "Stop monitoring before cleanup." : permanentIDs.isEmpty ? "Trash still uses disk space until it is emptied." : "\(permanentIDs.count) to delete permanently · \(m.staged.count - permanentIDs.count) to Trash after confirmation.",
                           horizontalPadding: 32) {
                Button(permanentIDs.isEmpty ? "move to trash…" : "clean up…", action: m.trashStaged)
                    .accessibilityLabel(permanentIDs.isEmpty ? "Move to Trash…" : "Clean Up…")
                    .buttonStyle(SMMacButtonStyle(.primary)).disabled(m.busy || m.monitoring)
            }
        }.background(AppColors.canvas)
    }
}

/// Auto Cleaner card: stale, usually-regenerable folders surfaced for review.
/// Suggestions never delete anything — each one stages through the same
/// preflight and review list as a manual pick.
private struct AutoCleanerCard: View {
    let scan: ScanResult
    let ids: [Int]
    @EnvironmentObject var m: ExplorerModel
    private var suggestions: [Int] { Array(ids.prefix(8)) }

    var body: some View {
        SMSettingsGroup("Rebuildable items", footer: "Caches, project dependencies and build outputs. Apps may need to download or rebuild them afterward. Nothing moves automatically.") {
            ViewThatFits(in: .horizontal) {
                HStack { summary; Spacer(minLength: 16); reviewButton }
                VStack(alignment: .leading, spacing: 12) { summary; reviewButton }
            }.padding(16)
            Divider().padding(.horizontal, 16)
            ForEach(suggestions, id: \.self) { id in
                let category = m.cleanupCategory(id) ?? .packageCaches
                SMResourceRow(StorageLabels.name(scan.nodes[id]),
                              subtitle: StorageLabels.location(scan.url(for: id).path),
                              systemImage: category.symbol) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 12) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(DiskFormat.bytes(scan.nodes[id].allocatedBytes)).monospacedDigit()
                            Text(category.title).font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        Button("inspect") { m.showCleanup = false; m.openStorage(.explore); m.open(scan.nodes[id]) }
                            .accessibilityLabel("Inspect").buttonStyle(SMMacButtonStyle(.quiet))
                        Button("add for review") { m.stage(id) }.accessibilityLabel("Add for Review").disabled(m.busy)
                    }
                }
                if id != suggestions.last { Divider().padding(.horizontal, 16) }
            }
            if ids.count > suggestions.count {
                Text("+ \(ids.count - suggestions.count) more included in Review items")
                    .font(.caption).foregroundStyle(Tints.secondaryText).padding(16)
            }
        }
    }

    private var reviewButton: some View {
        Button("Review \(ids.count) \(ids.count == 1 ? "item" : "items") (\(DiskFormat.bytes(totalBytes)))…", action: m.stageEasyCleanup)
            .buttonStyle(SMMacButtonStyle(.primary)).disabled(m.busy || m.monitoring)
    }
    private var totalBytes: Int64 { ids.reduce(0) { $0 + scan.nodes[$1].allocatedBytes } }

    private var summary: some View {
        Text("\(ids.count) \(ids.count == 1 ? "folder" : "folders") · \(DiskFormat.bytes(totalBytes))")
            .font(.caption).foregroundStyle(Tints.secondaryText)
    }
}
