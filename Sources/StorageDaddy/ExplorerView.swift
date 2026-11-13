@preconcurrency import MacTools
import SwiftUI
import SaaSMakerUI
import AppKit
import QuickLookUI
import DiskCore

struct ExplorerView: View {
    // Fixtures host the actual shell without app activation or scripted scans.
    var runsLaunchActions = true
    @EnvironmentObject var m: ExplorerModel
    @AppStorage("storageAccessIntroductionSeen") private var accessIntroductionSeen = false
    @State private var inspector = false
    @State private var choosingDisk = false
    @State private var toolsExpanded = false
    init(runsLaunchActions: Bool = true, inspector: Bool = false) {
        self.runsLaunchActions = runsLaunchActions
        _inspector = State(initialValue: inspector)
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    scopeBar
                    if m.busy { HStack { ProgressView().controlSize(.small); Text(m.progress).lineLimit(1); Spacer(); Button("cancel") { m.cancel() }.accessibilityLabel("Cancel") }.padding(12).background(AppColors.canvas) }
                    if !m.busy, m.exclusionResultsStale {
                        HStack {
                            Label("Exclusions changed. Rescan to update these results.", systemImage: "folder.badge.minus")
                            Spacer()
                            Button("rescan", action: m.rescan).accessibilityLabel("Rescan")
                        }.font(.callout).foregroundStyle(Tints.secondaryText).padding(12)
                    }
                    if !m.busy, let path = m.cleanupRefreshPaths.first {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Tints.mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Refresh after cleanup").fontWeight(.semibold)
                                Text("Rescan \(StorageLabels.location(path)) for current totals. Trash uses space until emptied.")
                                    .font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button("rescan now", action: m.rescanAfterCleanup).accessibilityLabel("Rescan now")
                                .disabled(!m.staged.isEmpty)
                                .help(m.staged.isEmpty ? "Refresh this location" : "Finish or remove your remaining cleanup selections before rescanning.")
                        }.padding(12).overlay(Rectangle().stroke(Tints.mint.opacity(0.25)))
                    }
                    if !m.busy, m.workspace == .explore, m.showWelcome || (!accessIntroductionSeen && m.scan == nil) { accessIntroduction }
                    else if m.isScanning, m.workspace == .explore, m.storageSection == .explore, let live = m.liveProgress { LiveScanView(progress: live) }
                    else if m.scan == nil, m.workspace.requiresScan || m.workspace == .explore { emptyState }
                    else { content }
                    Divider().overlay(Tints.secondaryText.opacity(0.18))
                    HStack(spacing: 14) {
                        Text(statusText).lineLimit(1)
                        Spacer()
                        if m.workspace == .explore, !m.busy, m.scan != nil, let rss = m.scanPeakRSS {
                            Text("Peak RSS \(DiskFormat.bytes(Int64(clamping: rss)))")
                                .monospacedDigit().foregroundStyle(Tints.secondaryText)
                                .help("App memory sampled every 50 ms during the scan and analysis. Includes the interface and retained results; brief spikes may be missed.")
                        }
                        if m.workspace == .explore, m.busy, let live = m.liveProgress {
                            Text(SpeedFormat.entriesPerSecond(entries: live.entries, elapsed: live.elapsed))
                                .monospacedDigit().foregroundStyle(Tints.mint)
                            Text(processDiskReadRateText(bytesRead: live.processDiskReadBytes, elapsed: live.elapsed))
                                .monospacedDigit().foregroundStyle(Tints.secondaryText)
                                .help(processDiskReadRateHelp)
                        } else if m.workspace == .explore, let scan = m.scan {
                            Text(SpeedFormat.entriesPerSecond(entries: scan.nodes.count, elapsed: scan.elapsed))
                                .monospacedDigit().foregroundStyle(Tints.mint)
                            Text(processDiskReadRateText(bytesRead: scan.processDiskReadBytes, elapsed: scan.elapsed))
                                .monospacedDigit().foregroundStyle(Tints.secondaryText)
                                .help(processDiskReadRateHelp)
                        }
                        Text("On-device only").foregroundStyle(Tints.secondaryText)
                    }.font(.custom(DaddyTheme.palette.sansFont, size: 10)).lineLimit(1).padding(.horizontal, 24).frame(height: 30)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspector, !m.busy, m.scan != nil, m.workspace == .explore, m.storageSection == .explore {
                    Divider().overlay(Tints.secondaryText.opacity(0.18)); InspectorView().frame(width: 250)
                }
            }.background(AppColors.canvas)
        }
        .font(.custom(DaddyTheme.palette.sansFont, size: 14))
        .background(SMWorkspaceWindowChrome())
        .storageTheme(DaddyTheme.palette)
        .buttonStyle(SMMacButtonStyle(.secondary))
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(isPresented: $choosingDisk) { DiskPickerView(isPresented: $choosingDisk).environmentObject(m).frame(width: 620, height: 560) }
        .sheet(isPresented: $m.showAbout) {
            VStack(spacing: 16) {
                if let icon = StorageDaddyAppDelegate.brandIcon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 120, height: 120)
                }
                Text("storagedaddy").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Make room for what’s next.").foregroundStyle(Tints.secondaryText)
                Text("Yours free forever, including all future versions.").font(.callout).foregroundStyle(Tints.mint)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                Button("done") { m.showAbout = false }.accessibilityLabel("Done").buttonStyle(SMMacButtonStyle(.primary))
            }.padding(32).frame(width: 340).background(AppColors.canvas)
        }
        .sheet(isPresented: Binding(get: { m.message != nil }, set: { if !$0 { m.message = nil } })) { StorageMessageSheet(message: m.message ?? "") }
        .sheet(isPresented: $m.showCleanup) { CleanupView().environmentObject(m).frame(width: 640, height: 490) }
        .modifier(EasyMovePresentation(model: m.moves))
        .onChange(of: m.progress) { _, progress in m.runtime.scanStatus = progress }
        .onChange(of: m.storageInspectorRequest) { _, _ in inspector = true }
        .onChange(of: m.busy) { _, busy in if busy && !StorageStartupCheck.enabled { accessIntroductionSeen = true } }
        .onAppear {
            guard runsLaunchActions else { return }
            NSApplication.shared.setActivationPolicy(.regular)
            StorageDaddyAppDelegate.applyIcon()
            if !StorageStartupCheck.enabled { NSApplication.shared.activate(ignoringOtherApps: true) }
            // Scripted-verification flags. A destination workspace outlives
            // the scan, which otherwise lands on Explore when it finishes.
            var destination: Workspace?
            if CommandLine.arguments.contains("--dashboard") { destination = .dashboard }
            if let index = CommandLine.arguments.firstIndex(of: "--workspace"),
               CommandLine.arguments.indices.contains(index + 1),
               let workspace = Workspace(rawValue: CommandLine.arguments[index + 1]) {
                destination = workspace
            }
            if let index = CommandLine.arguments.firstIndex(of: "--scan"), CommandLine.arguments.indices.contains(index + 1), m.scan == nil {
                if !StorageStartupCheck.enabled { accessIntroductionSeen = true }
                m.start(URL(fileURLWithPath: CommandLine.arguments[index + 1]), destination: destination)
            } else if let destination {
                if !StorageStartupCheck.enabled { accessIntroductionSeen = true }
                m.workspace = destination
            }
            if let index = CommandLine.arguments.firstIndex(of: "--mode"),
               CommandLine.arguments.indices.contains(index + 1),
               let mode = MapMode(rawValue: CommandLine.arguments[index + 1]) {
                m.mode = mode
            }
        }
    }

    private var statusText: String {
        switch m.workspace {
        case .aiSessions: m.aiSessionsSection == .archive ? "Local conversation archive" : "Local AI history inventory"
        case .applications: "Installed applications"
        case .dashboard: "Capacity, cleanup and system details"
        case .macControls: "Apple Intelligence, privacy and Mac settings"
        case .findFiles: "Filename search · Current scan metadata"
        case .acknowledgments: "About storagedaddy"
        default: m.progress
        }
    }

    private var processDiskReadRateHelp: String {
        "Average metadata I/O charged by macOS to the storagedaddy process during this scan. It is not SSD throughput or scanned size divided by time. Cached metadata can report 0 MB/s; other work in this process can contribute. Entries per second helps compare scans with similar scope on this Mac."
    }

    private func processDiskReadRateText(bytesRead: UInt64?, elapsed: Double) -> String {
        guard let rate = DiskReadMetric.megabytesPerSecond(bytesRead: bytesRead, elapsed: elapsed) else {
            return "Metadata I/O unavailable"
        }
        return String(format: "Metadata I/O %.1f MB/s", rate)
    }
    private var accessIntroduction: some View {
        ScanWelcomeView(
            scanDisk: { accessIntroductionSeen = true; m.showWelcome = false; choosingDisk = true },
            scanFolder: { accessIntroductionSeen = true; m.showWelcome = false; m.chooseFolder() },
            scanHome: { accessIntroductionSeen = true; m.showWelcome = false; m.scanHomeFolder() },
            scanCaches: { accessIntroductionSeen = true; m.showWelcome = false; m.scanUserCaches() },
            later: {
                accessIntroductionSeen = true
                m.showWelcome = false
                if m.scan == nil { m.workspace = .applications }
            }
        )
    }
    private var sidebar: some View {
        SMWorkspaceSidebar {
            HStack(spacing: 10) {
                BrandMark().frame(width: 32, height: 32)
                Text("storagedaddy").font(.custom(DaddyTheme.palette.displayFont, size: 18).weight(.semibold)).tracking(-0.5)
            }
        } navigation: {
            navigationItem(.dashboard, title: "Overview", symbol: "square.grid.2x2")
            navigationItem(.explore, title: "Storage", symbol: "internaldrive")
            navigationItem(.applications, symbol: "square.stack.3d.up")
            navigationItem(.aiSessions, title: "AI sessions", symbol: "bubble.left.and.bubble.right")
            navigationItem(.snapshots, symbol: "clock.arrow.circlepath")
            if toolsExpanded {
                Divider().padding(.vertical, 14)
                ForEach([Workspace.findFiles, .duplicates, .projects, .appData, .processes, .driveMonitoring, .agents, .macControls, .acknowledgments]) { item in
                    navigationItem(item)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 22) {
                if let scan = m.scan, let root = scan.nodes.first {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(StorageLabels.name(root), systemImage: "internaldrive")
                            .font(.custom(DaddyTheme.palette.sansFont, size: 11).weight(.medium)).lineLimit(1).help(scan.rootPath)
                        Text(m.scanStorageAccounting.map { "\(DiskFormat.bytes($0.capacity.available)) available" }
                             ?? "\(DiskFormat.bytes(root.allocatedBytes)) on disk")
                            .font(.custom(DaddyTheme.palette.sansFont, size: 11)).foregroundStyle(Tints.secondaryText)
                        if scan.skipped > 0 {
                            Button("\(scan.skipped.formatted()) skipped · Details") {
                                m.message = [m.scanStorageAccounting?.measuredBreakdown, m.scanStorageAccounting?.explanation, scan.coverageExplanation]
                                    .compactMap { $0 }.joined(separator: "\n\n")
                            }.font(.caption).buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 8)
                }
                HStack {
                    Button { toolsExpanded.toggle() } label: {
                        Label("Tools", systemImage: toolsExpanded ? "ellipsis.circle.fill" : "ellipsis.circle")
                    }.accessibilityIdentifier("sidebar-tools").accessibilityValue(toolsExpanded ? "Expanded" : "Collapsed")
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("open-settings")
                        .help("Settings (⌘,)")
                }.font(.custom(DaddyTheme.palette.sansFont, size: 12)).buttonStyle(.plain)
                    .foregroundStyle(Tints.secondaryText).padding(.horizontal, 8)
            }
        }
    }

    private func navigationItem(_ item: Workspace, title: String? = nil, symbol: String? = nil) -> some View {
        let storageSelected = [.explore, .cleanup, .developer].contains(m.workspace)
        return SMWorkspaceNavigationItem(title ?? item.title, systemImage: symbol ?? item.icon,
            isSelected: item == .explore ? storageSelected : m.workspace == item) {
                m.showWelcome = false
                if item == .explore { m.openStorage(m.storageSection) }
                else { m.workspace = item }
            }
            .accessibilityIdentifier("workspace-\(item.rawValue)")
            .help(item.requiresScan && m.scan == nil ? "Scan a disk or folder to see these results." : title ?? item.title)
    }

    private var scopeBar: some View {
        SMWorkspaceScopeBar(m.workspace == .explore ? "Storage" : m.workspace.title,
                            systemImage: m.workspace.icon,
                            detail: m.scan.map { StorageLabels.location($0.rootPath) }) {
            HStack(spacing: 8) {
                if m.workspace == .explore, m.scan != nil {
                    HStack(spacing: 4) {
                        ForEach(StorageSection.allCases) { section in
                            Button { m.openStorage(section) } label: {
                                Text(section == .developer ? "Developer" : section.rawValue)
                            }
                            .buttonStyle(SMMacButtonStyle(m.storageSection == section ? .primary : .quiet))
                            .accessibilityIdentifier("storage-section-\(section.rawValue)")
                            .accessibilityAddTraits(m.storageSection == section ? .isSelected : [])
                        }
                    }
                    Button { m.saveSnapshot() } label: {
                        Image(systemName: m.snapshotAlreadySaved ? "checkmark" : "square.and.arrow.down")
                    }.buttonStyle(SMMacButtonStyle(.quiet))
                        .accessibilityLabel(m.snapshotAlreadySaved ? "Snapshot Saved" : "Save Snapshot")
                        .disabled(m.busy || m.snapshotBusy || m.snapshotAlreadySaved)
                        .help(m.snapshotNotice ?? "Save this scan to local History. File contents are not copied.")
                }
                if m.workspace == .explore {
                    Menu {
                        Button("Scan a disk…") { choosingDisk = true }
                        Button("Scan a folder…", action: m.chooseFolder)
                        Button("Scan Home", action: m.scanHomeFolder)
                        Button("Scan caches", action: m.scanUserCaches)
                    } label: { Label(m.scan == nil ? "Scan…" : "New scan…", systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(m.busy)
                        .accessibilityLabel(m.scan == nil ? "Start Scan…" : "New Scan…")
                }
            }
        }
    }
    private var emptyState: some View {
        ScanWelcomeView(
            scanDisk: { choosingDisk = true },
            scanFolder: m.chooseFolder,
            scanHome: m.scanHomeFolder,
            scanCaches: m.scanUserCaches
        )
    }
    @ViewBuilder private var content: some View {
        switch m.workspace {
        case .processes:
            GeometryReader { geometry in
                RuntimeView(model: m.runtime)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        case .driveMonitoring: DriveMonitoringView(model: m.runtime)
        case .agents: AgentAccessView(agents: m.agentAccess)
        case .macControls: StorageDaddyMacToolsView(session: m.macToolsSession(), accent: Tints.mint, secondaryInk: Tints.secondaryText, operationAllowed: !m.busy && !m.monitoring && m.staged.isEmpty && !m.snapshotBusy && !m.conversationArchive.busy)
            .onAppear { m.macTools?.setExcludedFolders(m.excludedFolders) }
            .onChange(of: m.excludedFolders) { _, paths in m.macTools?.setExcludedFolders(paths) }
        case .findFiles: FilenameSearchView()
        case .explore: storageWorkspace
        case .applications: ApplicationsView(applications: m.installedApplications)
        case .aiSessions:
            GeometryReader { geometry in
                AISessionsView()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        case .snapshots: SavedHistoryView()
        case .dashboard: DashboardView(dashboard: m.dashboard)
        case .cleanup: CleanupView()
        case .duplicates:
            if let scan = m.scan {
                DuplicateReviewView(scan: scan, groups: m.duplicateGroups, isLoading: m.duplicatesLoading,
                    error: m.duplicatesError, onFind: m.findDuplicates, onCancel: m.invalidateDuplicateReview,
                    onStage: m.stageDuplicateCopies, hasSearched: m.duplicatesSearched, log: m.duplicateLog,
                    onMove: { ids in m.moves.reviewCopies(ids: ids, scan: scan, excludedFolders: m.excludedFolders) })
                    .id("\(scan.started):\(scan.rootPath)")
            }
        case .developer: DeveloperView()
        case .projects:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button("refresh project evidence", action: m.reviewProjects).accessibilityLabel("Refresh project evidence")
                        .buttonStyle(SMMacButtonStyle(.secondary)).disabled(m.busy || m.projectReviewStatus == .loading)
                    if m.projectReviewStatus == .loading {
                        Button("cancel review", action: m.cancelProjectReview).accessibilityLabel("Cancel review").buttonStyle(SMMacButtonStyle(.secondary))
                    }
                    ProjectPurgeView(records: m.projectReviewRecords, scan: m.scan, status: m.projectReviewStatus,
                        onRecoveryPlan: m.recordProjectRecoveryPlan, onRetry: m.reviewProjects, onStageArtifactIDs: m.stageProjectArtifacts)
                }.padding(30)
            }
        case .appData:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button("refresh app reference", action: m.refreshAppDataReview).accessibilityLabel("Refresh app reference")
                            .buttonStyle(SMMacButtonStyle(.secondary)).disabled(m.busy || m.appDataReviewLoading)
                        if m.appDataReviewLoading {
                            ProgressView().controlSize(.small); Text("Reviewing app metadata…")
                            Button("cancel", action: m.cancelAppDataReview).accessibilityLabel("Cancel").buttonStyle(SMMacButtonStyle(.secondary))
                        }
                    }
                    Text("Reference covers visible apps in standard application folders. Apps installed elsewhere, ownership and removal safety remain unknown.")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                    if let error = m.appDataReviewError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.coral) }
                    if let result = m.appDataReview {
                        AppLeftoverReviewView(result: result, reviewEnabled: !m.busy && !m.appDataReviewLoading,
                            onInspect: m.inspectAppData, onReview: m.stageAppData)
                    } else if !m.appDataReviewLoading {
                        Text("Refresh the app reference to review direct Library data roots in this scan.").foregroundStyle(Tints.secondaryText)
                    }
                }.padding(30)
            }
        case .acknowledgments: AcknowledgmentsView()
        }
    }
    private var storageWorkspace: some View {
        Group {
            switch m.storageSection {
            case .explore: explorer
            case .developer: DeveloperView()
            case .cleanup: CleanupView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var explorer: some View { StorageExplorePanel(inspector: $inspector) }
}

struct StorageExplorePanel: View {
    @EnvironmentObject var m: ExplorerModel
    @Binding var inspector: Bool
    @State private var explainingSizes = false
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || geometry.size.height < 650
            ScrollView {
                panel(compact: compact, scrolling: true)
            }
        }
    }
    private func panel(compact: Bool, scrolling: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            let headerLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
            headerLayout {
              HStack {
                DoodleArt(topic: .explore).frame(width: 48, height: 48)
                Button(action: m.goUp) { Image(systemName: "chevron.left") }.disabled(m.focus == 0).help("Parent folder")
                VStack(alignment: .leading, spacing: 3) {
                    if let scan = m.scan, scan.nodes.indices.contains(m.focus) {
                        Text(StorageLabels.name(scan.nodes[m.focus])).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                        Text(StorageLabels.location(scan.url(for: m.focus).path)).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle).help(scan.url(for: m.focus).path)
                    } else {
                        Text("Folder").font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                }
              }
                if !compact { Spacer() }
              HStack {
                Button(action: m.rescan) { Label("rescan", systemImage: "arrow.clockwise").accessibilityLabel("Rescan") }
                    .buttonStyle(SMMacButtonStyle(.secondary))
                    .disabled(m.scan == nil || m.busy)
                Button { inspector.toggle() } label: { Label("inspector", systemImage: "sidebar.right").accessibilityLabel("Inspector") }
                    .buttonStyle(SMMacButtonStyle((inspector) ? .primary : .secondary))
                    .help(inspector ? "Hide Inspector" : "Show Inspector")
                    .accessibilityAddTraits(inspector ? .isSelected : [])
              }.fixedSize()
            TextField("Filter this folder", text: $m.search)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(AppColors.canvas)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tints.mint.opacity(0.45), lineWidth: 1))
                .frame(maxWidth: 220)
            }
            let controlsLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
            controlsLayout {
              HStack {
                Menu {
                    ForEach(MapMode.allCases) { mode in
                        Button { m.mode = mode } label: { Label(mode.rawValue, systemImage: mode.icon) }
                    }
                } label: { Label(m.mode.rawValue, systemImage: m.mode.icon).padding(.horizontal, 10).padding(.vertical, 6) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .background(AppColors.canvas)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tints.mint.opacity(0.4), lineWidth: 1))
                    .accessibilityLabel("View: \(m.mode.rawValue)")
                if ![.folders, .top, .age, .types].contains(m.mode) {
                    Picker("Tile area", selection: $m.mapMeasure) {
                        ForEach(MapMeasure.allCases) { measure in Text(measure.rawValue.lowercased()).accessibilityLabel(measure.rawValue).tag(measure) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 190)
                }
              }
                if !compact { Spacer() }
                HStack(spacing: 6) {
                    Button { explainingSizes = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Explain disk usage, scan coverage and file sizes")
                        .popover(isPresented: $explainingSizes) { ScrollView { SizeExplanationView(accounting: m.scanStorageAccounting, scan: m.scan).padding(22) }.frame(width: 420, height: 480).background(AppColors.canvas) }
                    Button("on disk") { m.allocated = true }.accessibilityLabel("On disk")
                        .buttonStyle(SMMacButtonStyle((m.allocated) ? .primary : .secondary))
                        .accessibilityAddTraits(m.allocated ? .isSelected : [])
                    Button("logical") { m.allocated = false }.accessibilityLabel("Logical")
                        .buttonStyle(SMMacButtonStyle((!m.allocated) ? .primary : .secondary))
                        .accessibilityAddTraits(!m.allocated ? .isSelected : [])
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let scan = m.scan, scan.nodes.indices.contains(m.focus) {
                controlsLayout {
                    Text(m.focus == 0 && m.allocated ? m.scanStorageAccounting?.summary ?? m.folderSizeDescription(scan.nodes[m.focus]) : m.folderSizeDescription(scan.nodes[m.focus])).fontWeight(.medium)
                        .help(m.scanStorageAccounting.map { $0.explanation + "\n\nCapacity measured after this scan; rescan to update." } ?? "Totals include only files reached by this scan.")
                    if !compact { Spacer() }
                    if !compact {
                        Text("Select to inspect · Option-click or M to mark · Double-click to open")
                            .foregroundStyle(Tints.secondaryText)
                    }
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if m.allocated {
                Text("Shared files and snapshots can make file totals differ from disk usage.")
                    .font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .help(ScanStorageAccounting.fileAllocationExplanation)
            }
            if let scan = m.scan, ChromeSigningClones.location(path: scan.url(for: m.focus).path) != nil {
                ChromeSigningCopiesView(nodeID: m.focus)
            }
            Divider().overlay(Tints.secondaryText.opacity(0.18))
            StorageFreeSpaceView().fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            if m.mapItems.isEmpty || ([.folders, .top, .age, .types].contains(m.mode) && m.visible.isEmpty) { StorageEmptyView("No matching items", systemImage: "folder", description: Text("Try another filter or open a different folder.")) }
            else if m.mode == .folders { folderList.frame(height: scrolling ? 400 : nil) }
            else { DiskMapView(compact: scrolling, chartHeight: compact ? 260 : 380).frame(minHeight: scrolling && [.top, .age, .types].contains(m.mode) ? 400 : 0) }
        }.padding(compact ? 16 : 26)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var folderList: some View {
        List(m.visible, selection: $m.selected) { n in
            Button { m.selected = n.id } label: {
                HStack(spacing: 14) {
                    Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").font(.title3).foregroundStyle(Tints.forNode(n)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) { Text(StorageLabels.name(n)).font(.system(size: 15, weight: .medium)); Text(n.isDirectory ? "\(n.children.count) items" : n.modified == .distantPast || !n.modified.timeIntervalSince1970.isFinite ? "Unknown" : n.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Tints.secondaryText) }
                    Spacer()
                    Text(m.itemSizeDescription(n)).monospacedDigit().foregroundStyle(Tints.secondaryText)
                    if n.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tints.secondaryText.opacity(0.7)) }
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).simultaneousGesture(TapGesture(count: 2).onEnded { m.open(n) })
                .listRowBackground(m.selected == n.id ? Tints.mint.opacity(0.1) : AppColors.canvas)
                .contextMenu { StorageItemMenu(node: n) }
                .tag(n.id)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(AppColors.canvas)
            .onKeyPress(.return) { openKeyboardSelection() }
            .onKeyPress(.delete) {
                guard let id = m.selected, !m.busy else { return .ignored }
                m.stage(id); return .handled
            }
    }
    private func openKeyboardSelection() -> KeyPress.Result {
        guard let scan = m.scan, let id = m.selected, scan.nodes.indices.contains(id), !m.busy else { return .ignored }
        if scan.nodes[id].isDirectory { m.open(scan.nodes[id]) }
        else { NSWorkspace.shared.open(scan.url(for: id)) }
        return .handled
    }
}

struct StorageFreeSpaceView: View {
    @EnvironmentObject var m: ExplorerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Free now: \(m.volumeFree.map(DiskFormat.bytes) ?? "Unavailable")" +
                 (m.staged.isEmpty ? "" : " · \(m.stagedExclusiveBytes.map(DiskFormat.bytes) ?? "Unknown") exclusive allocation selected"))
                .font(.caption).monospacedDigit().foregroundStyle(Tints.mint)
                .fixedSize(horizontal: false, vertical: true)
            if !m.staged.isEmpty {
                Text("Review selections before moving them to Trash. Empty Trash to reclaim space.")
                    .font(.caption2).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .help("Exclusive bytes are a conservative estimate; additional shared-block recovery is unknown.")
            }
        }
    }
}

enum Tints {
    static let electricBlue = DaddyPalette.blue
    static let mint = AppColors.mint
    static let secondaryText = AppColors.secondary
    static let coral = DaddyPalette.coral
    static let yellow = DaddyPalette.amber
    static let cyan = DaddyPalette.cyan
    static let colors: [Color] = [mint, electricBlue, coral, yellow, cyan]

    static func forKind(_ kind: StorageKind) -> Color {
        switch kind {
        case .code: mint
        case .caches: yellow
        case .toolchains: electricBlue
        case .packages: cyan
        case .git: Color(red: 0.67, green: 0.77, blue: 0.49)
        case .media: Color(red: 0.91, green: 0.63, blue: 0.45)
        case .documents: Color(red: 0.74, green: 0.79, blue: 0.81)
        case .agents: Color(red: 0.45, green: 0.72, blue: 0.87)
        case .generic: Color(white: 0.56)
        }
    }

    static func forMapNode(_ node: DiskNode, kind: StorageKind) -> Color {
        kind == .generic ? forLocation(node.name) : forKind(kind)
    }

    static func forLocation(_ name: String) -> Color {
        switch name.lowercased() {
        case "users": electricBlue
        case "applications": mint
        case "system": coral
        case "library": yellow
        default: forName(name)
        }
    }

    static func forNode(_ n: DiskNode) -> Color {
        forName(n.name)
    }

    private static func forName(_ name: String) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

struct InspectorView: View {
    @EnvironmentObject var m: ExplorerModel
    @State private var preview: PreviewSelection?
    var body: some View {
        ScrollView {
            if let n = m.node, let scan = m.scan {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 44)).foregroundStyle(Tints.forNode(n))
                    Text(StorageLabels.name(n)).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(StorageLabels.location(scan.url(for: n.id).path)).font(.caption).foregroundStyle(Tints.secondaryText).help(scan.url(for: n.id).path).textSelection(.enabled)
                    Text(m.allocated && n.allocatedBytes == 0 && (m.allocationSummary(n)?.sharedFiles ?? 0) > 0 ? "Shared storage" : StorageLabels.size(n, allocated: m.allocated, compact: true)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().help(StorageLabels.size(n, allocated: m.allocated))
                    Divider().overlay(Tints.secondaryText.opacity(0.18))
                    metric("Attributed allocation", StorageLabels.size(n, allocated: true)); metric("Logical", StorageLabels.size(n, allocated: false)); metric("Modified", n.modified == .distantPast || !n.modified.timeIntervalSince1970.isFinite ? "Unknown" : n.modified.formatted(date: .abbreviated, time: .omitted)); metric("Contents", n.isContentsUnreadable == true ? "Not enumerated" : "\(n.children.count) immediate items\(n.isScanIncomplete == true ? " · incomplete" : "")")
                    StorageAllocationDetailsView(node: n)
                    metric("Kind", m.storageKind(n).rawValue)
                    metric("File entries", m.fileEntries(n).formatted())
                    if n.isDirectory, n.children.contains(where: { scan.nodes[$0].name == ".git" }) {
                        GitEvidenceView(url: scan.url(for: n.id))
                    }
                    Text("Allocated totals can include shared APFS blocks. They are not a promise of reclaimable space.").font(.caption).foregroundStyle(Tints.secondaryText)
                    if n.isDirectory {
                        FolderSymlinksView(scan: scan, folderID: n.id)
                            .id("\(scan.started.timeIntervalSince1970):\(scan.rootPath):\(n.id)")
                    }
                    Divider().overlay(Tints.secondaryText.opacity(0.18))
                    Button("reveal in finder", systemImage: "arrow.up.forward.square") { m.reveal(n.id) }.accessibilityLabel("Reveal in Finder")
                    if !n.isDirectory { Button("quick look", systemImage: "eye") { preview = PreviewSelection(url: scan.url(for: n.id)) }.accessibilityLabel("Quick Look") }
                    Button("copy path", systemImage: "doc.on.doc") { m.copyPath(n.id) }.accessibilityLabel("Copy Path")
                    if n.isDirectory {
                        Button("explain this folder", systemImage: "sparkles") { m.explainFolder(n.id) }.accessibilityLabel("Explain This Folder")
                            .help("Ask your local Claude or Codex install to explain this folder. Its path, scan measurements and detected folder context are sent.")
                        Button("copy ask ai prompt", systemImage: "doc.on.doc") { m.copyFolderPrompt(n.id) }.accessibilityLabel("Copy Ask AI Prompt")
                            .help("Copy a ready-to-paste prompt that asks an AI assistant to explain this folder. Nothing is uploaded.")
                    }
                    if n.isDirectory { Button("open folder", systemImage: "folder") { m.open(n) }.accessibilityLabel("Open Folder") }
                    if ChromeSigningClones.location(path: scan.url(for: n.id).path) != nil {
                        Label("Signing copy · Quit Chrome first", systemImage: "square.on.square").font(.caption).foregroundStyle(Tints.yellow)
                    } else { CleanupFlag(category: m.cleanupCategory(n.id)) }
                    if let assessment = FolderArchetypes.assess(scan, folderID: n.id, category: m.cleanupCategory(n.id)) {
                        Text(assessment.explanation).font(.caption).foregroundStyle(Tints.secondaryText).textSelection(.enabled)
                    }
                    if let note = CleanupGuidance.chromeCacheNote(path: scan.url(for: n.id).path) {
                        Text(note).font(.caption).foregroundStyle(Tints.yellow)
                    }
                    if ChromeSigningClones.location(path: scan.url(for: n.id).path) == .store {
                        Button("Review signing copies", systemImage: "tray.and.arrow.down") { m.stageChromeSigningCopies(n.id) }
                            .buttonStyle(SMMacButtonStyle(.primary)).disabled(m.busy || m.monitoring)
                    } else {
                        Button(m.staged.contains(n.id) ? "Staged for Cleanup" : "Add to Cleanup", systemImage: "tray.and.arrow.down") { m.stage(n.id) }.buttonStyle(SMMacButtonStyle(.primary)).disabled(m.staged.contains(n.id) || m.busy || m.monitoring || n.parent == nil)
                    }
                    if scan.skipped > 0 {
                        Text("Some locations were skipped. Add to Cleanup checks this item separately and asks you to review any contents it cannot verify.")
                            .font(.caption).foregroundStyle(Tints.yellow)
                        Button("scan this folder", systemImage: "arrow.clockwise") {
                            m.start(n.isDirectory ? scan.url(for: n.id) : scan.url(for: n.id).deletingLastPathComponent())
                        }.accessibilityLabel("Scan This Folder").disabled(m.busy)
                    } else if n.parent == nil {
                        Text("The scan root is protected. Select an item inside this folder to review cleanup.").font(.caption).foregroundStyle(Tints.secondaryText)
                    } else if m.monitoring {
                        Text("Stop monitoring before staging cleanup.").font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                    if !n.children.isEmpty {
                        Divider().overlay(Tints.secondaryText.opacity(0.18)); Text("largest inside").accessibilityLabel("LARGEST INSIDE").font(.caption).foregroundStyle(Tints.secondaryText)
                        ForEach(Array(n.children.map { scan.nodes[$0] }.sorted { m.bytes($0) > m.bytes($1) }.prefix(8))) { child in
                            Button { m.selected = child.id } label: { HStack { Text(StorageLabels.name(child)).lineLimit(1); Spacer(); Text(StorageLabels.size(child, allocated: m.allocated)) }.font(.caption) }.buttonStyle(.plain).contextMenu { StorageItemMenu(node: child) }
                        }
                    }
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            } else { StorageEmptyView("Inspect an item", systemImage: "cursorarrow.click", description: Text("Select a file or folder to see its details.")).padding(.top, 70) }
        }.sheet(item: $m.folderExplanation) { state in
            FolderExplanationView(state: state)
        }
        .sheet(item: $preview) { item in
            VStack(spacing: 0) {
                HStack {
                    Text(item.url.lastPathComponent).font(.headline).lineLimit(1)
                    Spacer()
                    Button("done") { preview = nil }.accessibilityLabel("Done").keyboardShortcut(.cancelAction)
                }.padding(16)
                NativePreview(url: item.url)
                HStack {
                    Text("No preview? Open its location in Finder.").font(.caption).foregroundStyle(Tints.secondaryText)
                    Spacer()
                    Button("reveal in finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.accessibilityLabel("Reveal in Finder")
                }.padding(16)
            }
            .frame(width: 700, height: 540)
            .background(AppColors.canvas)
            .buttonStyle(SMMacButtonStyle(.secondary))
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).foregroundStyle(Tints.secondaryText)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.font(.caption)
    }
}

private struct PreviewSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct NativePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.previewItem = url as NSURL; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}

struct BrandMark: View {
    @Environment(\.storageArtworkDirectory) private var artworkDirectory
    var body: some View {
        if let image = StorageArtwork.image("StorageDaddy", directory: artworkDirectory) { Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true) }
        else { Image(systemName: "externaldrive.fill").resizable().scaledToFit().foregroundStyle(Tints.mint).accessibilityHidden(true) }
    }
}
