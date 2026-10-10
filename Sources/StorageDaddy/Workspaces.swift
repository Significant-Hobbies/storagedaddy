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
        .background(Color.black)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack { SMSectionHeader("Review Cleanup", size: 28).accessibilityLabel("Review Cleanup"); DoodleArt(topic: .cleanup).frame(width: 72, height: 72); Spacer(); if m.showCleanup { Button("done") { m.showCleanup = false }.accessibilityLabel("Done") } }
            Text(m.staged.isEmpty ? "Add files and folders from Explore or Developer Insights. Nothing is removed until you confirm." : "Review the list before moving it to Trash. Items added with an incomplete check are marked below. We check paths and known contents again after confirmation.").foregroundStyle(Tints.secondaryText)
            if !m.showCleanup && m.staged.isEmpty { TrashInventoryView() }
            if let scan = m.scan, !m.autoCleanerSuggestions.isEmpty {
                AutoCleanerCard(scan: scan)
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
            } else if m.staged.isEmpty {
                StorageEmptyView("Choose what to clean up", systemImage: "tray", description: Text("Right-click a file or folder and choose Add to Cleanup. Each item is checked before it appears here."))
                if !m.easyCleanupIDs.isEmpty {
                    Button("Easy Cleanup — stage \(m.easyCleanupIDs.count) regenerable items (\(DiskFormat.bytes(m.easyCleanupBytes)))…", action: m.stageEasyCleanup)
                        .buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.busy || m.monitoring)
                    Text("Stale builds, dependency folders and package caches. Each is verified, then listed here for your confirmation — nothing moves until Move to Trash.").font(.caption).foregroundStyle(Tints.secondaryText)
                }
            }
            else if let scan = m.scan {
                List(m.staged.sorted(), id: \.self) { id in
                    HStack(alignment: .top) {
                        Image(systemName: scan.nodes[id].isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(Tints.forNode(scan.nodes[id])).font(.title3).frame(width: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(StorageLabels.name(scan.nodes[id]))
                            CleanupFlag(category: m.cleanupCategory(id))
                            Text(StorageLabels.location(scan.url(for: id).path)).help(scan.url(for: id).path).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                            if let note = CleanupGuidance.chromeCacheNote(path: scan.url(for: id).path) {
                                Text(note).font(.caption).foregroundStyle(Tints.yellow)
                            }
                            if let review = m.incompleteCleanup[id] {
                                Label("Added anyway · \(review.skipped) \(review.skipped == 1 ? "item" : "items") not checked", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Tints.coral)
                                Button("review warning") { m.reviewIncompleteCleanup(id) }.accessibilityLabel("Review warning").font(.caption).disabled(m.busy)
                            }
                            if scan.nodes[id].isDirectory {
                                FolderSymlinksView(scan: scan, folderID: id, cleanupReview: true)
                                    .id("\(scan.started.timeIntervalSince1970):\(scan.rootPath):\(id)")
                                    .frame(maxWidth: 540, alignment: .leading)
                            }
                        }
                        Spacer()
                        Text(DiskFormat.bytes(scan.nodes[id].allocatedBytes)).monospacedDigit()
                            .foregroundStyle(Tints.forNode(scan.nodes[id])).frame(width: 104, alignment: .trailing)
                        Button("remove") { m.unstage(id) }.accessibilityLabel("Remove").disabled(m.busy)
                    }.accessibilityElement(children: .contain).listRowBackground(Color.black)
                }.scrollContentBackground(.hidden).listStyle(.plain)
                HStack { Text("\(m.staged.count) \(m.staged.count == 1 ? "item" : "items") · \(DiskFormat.bytes(m.staged.reduce(0) { $0 + scan.nodes[$1].allocatedBytes })) allocated").fontWeight(.medium); Spacer(); Button("move to trash…", action: m.trashStaged).accessibilityLabel("Move to Trash…").buttonStyle(StorageButtonStyle(prominent: true)).tint(Tints.coral).disabled(m.busy || m.monitoring) }
                Text("Trash still uses disk space until it is emptied.").font(.caption).foregroundStyle(Tints.secondaryText)
                if m.monitoring { Text("Stop monitoring before cleanup.").font(.caption).foregroundStyle(Tints.secondaryText) }
            }
        }.padding(24)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.background(Color.black).buttonStyle(StorageButtonStyle())
    }
}

/// Auto Cleaner card: stale, usually-regenerable folders surfaced for review.
/// Suggestions never delete anything — each one stages through the same
/// preflight and review list as a manual pick.
private struct AutoCleanerCard: View {
    let scan: ScanResult
    @EnvironmentObject var m: ExplorerModel

    private var suggestions: [AutoCleanerSuggestion] { Array(m.autoCleanerSuggestions.prefix(6)) }
    private var totalBytes: Int64 { m.autoCleanerSuggestions.reduce(0) { $0 + $1.allocatedBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Tints.yellow)
                Text("Auto Cleaner").font(.headline)
                Text("\(m.autoCleanerSuggestions.count) stale \(m.autoCleanerSuggestions.count == 1 ? "folder" : "folders") · \(DiskFormat.bytes(totalBytes))")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            Text("Suggestions only — nothing moves automatically. Modification dates are metadata, not proof a folder is unused.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            Button("Easy Cleanup — stage all \(m.easyCleanupIDs.count) regenerable items (\(DiskFormat.bytes(m.easyCleanupBytes)))…", action: m.stageEasyCleanup)
                .font(.callout).buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.busy || m.monitoring || m.easyCleanupIDs.isEmpty)
            ForEach(suggestions) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: suggestion.category.symbol)
                        .foregroundStyle(suggestion.category.color).font(.title3).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(StorageLabels.name(scan.nodes[suggestion.id])).font(.callout)
                        Text("\(suggestion.category.title) · unchanged \(suggestion.staleDays) days")
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                        Text(suggestion.path).font(.caption2).foregroundStyle(Tints.secondaryText.opacity(0.8))
                            .lineLimit(1).truncationMode(.middle).help(suggestion.path)
                    }
                    Spacer()
                    Text(DiskFormat.bytes(suggestion.allocatedBytes)).font(.caption).monospacedDigit()
                    Button("inspect") {
                        m.showCleanup = false
                        m.workspace = .explore
                        if scan.nodes.indices.contains(suggestion.id) { m.open(scan.nodes[suggestion.id]) }
                    }.accessibilityLabel("Inspect").font(.caption)
                    Button("add for review") { m.stage(suggestion.id) }.accessibilityLabel("Add for Review").font(.caption).disabled(m.busy)
                }
            }
            if m.autoCleanerSuggestions.count > suggestions.count {
                Text("+ \(m.autoCleanerSuggestions.count - suggestions.count) more in Developer Insights")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
        .padding(14)
        .storagePanel()
    }
}
