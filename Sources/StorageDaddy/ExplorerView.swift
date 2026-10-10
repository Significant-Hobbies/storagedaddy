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
    init(runsLaunchActions: Bool = true, inspector: Bool = false) {
        self.runsLaunchActions = runsLaunchActions
        _inspector = State(initialValue: inspector)
    }
    var body: some View {
        NavigationSplitView {
            ScrollView { sidebar }
                .background(Color.black).navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if m.busy { HStack { ProgressView().controlSize(.small); Text(m.progress).lineLimit(1); Spacer(); Button("cancel") { m.cancel() }.accessibilityLabel("Cancel") }.padding(12).background(Color.black) }
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
                    if !m.busy, m.showWelcome || (!accessIntroductionSeen && m.scan == nil && m.workspace == .explore) { accessIntroduction }
                    else if m.busy, let live = m.liveProgress { LiveScanView(progress: live) }
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
                    }.font(.caption).lineLimit(1).padding(10)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspector, !m.busy, m.scan != nil, m.workspace == .explore, m.storageSection == .explore {
                    Divider().overlay(Tints.secondaryText.opacity(0.18)); InspectorView().frame(width: 250)
                }
            }.background(Color.black)
        }
        .font(.custom(DaddyTheme.palette.sansFont, size: 13))
        .smTheme(DaddyTheme.palette)
        .buttonStyle(StorageButtonStyle())
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
                Button("done") { m.showAbout = false }.accessibilityLabel("Done").buttonStyle(StorageButtonStyle(prominent: true))
            }.padding(32).frame(width: 340).background(Color.black)
        }
        .sheet(isPresented: Binding(get: { m.message != nil }, set: { if !$0 { m.message = nil } })) { StorageMessageSheet(message: m.message ?? "") }
        .sheet(isPresented: $m.showCleanup) { CleanupView().environmentObject(m).frame(width: 640, height: 490) }
        .onChange(of: m.storageInspectorRequest) { _, _ in inspector = true }
        .onChange(of: m.busy) { _, busy in if busy { accessIntroductionSeen = true } }
        .onAppear {
            guard runsLaunchActions else { return }
            NSApplication.shared.setActivationPolicy(.regular)
            StorageDaddyAppDelegate.applyIcon()
            NSApplication.shared.activate(ignoringOtherApps: true)
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
                accessIntroductionSeen = true
                m.start(URL(fileURLWithPath: CommandLine.arguments[index + 1]), destination: destination)
            } else if let destination {
                accessIntroductionSeen = true
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) { BrandMark().frame(width: 24, height: 24); Text("storagedaddy").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(-0.6).lineLimit(1).minimumScaleFactor(0.8) }.padding(.top, 20).padding(.bottom, 10)
            VStack(spacing: 8) {
                Button { choosingDisk = true } label: { Label(m.scan == nil ? "start scan…" : "new scan…", systemImage: "internaldrive.fill").frame(maxWidth: .infinity).frame(height: 28) }.buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.busy).accessibilityLabel(m.scan == nil ? "Start Scan…" : "New Scan…")
                Button(action: m.chooseFolder) { Label("scan folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity).frame(height: 28) }.buttonStyle(StorageButtonStyle()).disabled(m.busy).accessibilityLabel("Scan Folder…")
            }
            VStack(alignment: .leading, spacing: 5) {
                navigationHeading("STORAGE")
                navigationItem(.explore)
                navigationItem(.findFiles)
                navigationItem(.snapshots)
                navigationItem(.duplicates)
                navigationItem(.projects)
                navigationItem(.appData)
                navigationHeading("TOOLS").padding(.top, 9)
                navigationItem(.dashboard)
                navigationItem(.applications)
                navigationItem(.aiSessions)
                navigationItem(.macControls)
            }
            Spacer(minLength: 12)
            if let scan = m.scan, let root = scan.nodes.first {
                VStack(alignment: .leading, spacing: 7) {
                    Text("current scan").accessibilityLabel("CURRENT SCAN").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Tints.secondaryText)
                    Text(StorageLabels.name(root)).font(.callout).lineLimit(1).help(scan.rootPath)
                    Text("\(DiskFormat.bytes(root.allocatedBytes)) on disk").font(.callout).monospacedDigit()
                    if scan.skipped > 0 {
                        Button("\(scan.skipped.formatted()) skipped · Details") {
                            m.message = [m.scanStorageAccounting?.measuredBreakdown, m.scanStorageAccounting?.explanation, scan.coverageExplanation]
                                .compactMap { $0 }.joined(separator: "\n\n")
                        }.font(.caption)
                    }
                }.padding(.vertical, 12)
            }
            SettingsLink {
                Label("settings", systemImage: "gearshape").accessibilityLabel("Settings")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(StorageButtonStyle())
            .accessibilityIdentifier("open-settings")
            .help("Open Settings to manage excluded folders and update preferences (⌘,)")
            Text("Nothing is removed until you review it.").font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }
    private func navigationHeading(_ title: String) -> some View {
        Text(title.lowercased()).font(.custom(DaddyTheme.palette.sansFont, size: 10).weight(.semibold))
            .foregroundStyle(Tints.secondaryText).padding(.horizontal, 10).padding(.vertical, 4)
    }
    private func navigationItem(_ item: Workspace) -> some View {
        let needsScan = m.scan == nil && item.requiresScan
        return Button {
            m.showWelcome = false
            if item == .explore { m.openStorage(m.storageSection) }
            else { m.workspace = item }
        } label: {
            HStack {
                Image(systemName: item.icon).frame(width: 20)
                Text(item.title.lowercased()).accessibilityLabel(item.title)
                Spacer()
                if item == .cleanup, !m.staged.isEmpty { Text("\(m.staged.count)").monospacedDigit() }
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(m.workspace == item && !needsScan ? Tints.mint.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .disabled(needsScan)
        .help(item == .snapshots ? "Browse snapshots saved from your scan results."
              : needsScan ? "Scan a disk or folder to see these results." : item.title)
        .accessibilityIdentifier("workspace-\(item.rawValue)")
        .accessibilityAddTraits(m.workspace == item && !needsScan ? .isSelected : [])
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
                    onStage: m.stageDuplicateCopies, hasSearched: m.duplicatesSearched)
                    .id("\(scan.started):\(scan.rootPath)")
            }
        case .developer: DeveloperView()
        case .projects:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button("refresh project evidence", action: m.reviewProjects).accessibilityLabel("Refresh project evidence")
                        .buttonStyle(StorageButtonStyle()).disabled(m.busy || m.projectReviewStatus == .loading)
                    if m.projectReviewStatus == .loading {
                        Button("cancel review", action: m.cancelProjectReview).accessibilityLabel("Cancel review").buttonStyle(StorageButtonStyle())
                    }
                    ProjectPurgeView(records: m.projectReviewRecords, scan: m.scan, status: m.projectReviewStatus,
                        onRecoveryPlan: m.recordProjectRecoveryPlan, onRetry: m.reviewProjects, onStageArtifactIDs: m.stageProjectArtifacts)
                }.padding(20)
            }
        case .appData:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button("refresh app reference", action: m.refreshAppDataReview).accessibilityLabel("Refresh app reference")
                            .buttonStyle(StorageButtonStyle()).disabled(m.busy || m.appDataReviewLoading)
                        if m.appDataReviewLoading {
                            ProgressView().controlSize(.small); Text("Reviewing app metadata…")
                            Button("cancel", action: m.cancelAppDataReview).accessibilityLabel("Cancel").buttonStyle(StorageButtonStyle())
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
                }.padding(20)
            }
        case .acknowledgments: AcknowledgmentsView()
        }
    }
    private var storageWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(StorageSection.allCases) { section in
                    Button {
                        m.openStorage(section)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: section.icon)
                            Text(section.rawValue.lowercased()).accessibilityLabel(section.rawValue)
                            if section == .cleanup, !m.staged.isEmpty {
                                Text(m.staged.count.formatted()).monospacedDigit()
                            }
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(StorageButtonStyle(prominent: m.storageSection == section))
                    .accessibilityIdentifier("storage-section-\(section.rawValue)")
                    .accessibilityAddTraits(m.storageSection == section ? .isSelected : [])
                }
                Spacer()
                if let scan = m.scan {
                  ViewThatFits(in: .horizontal) {
                    Text(StorageLabels.location(scan.rootPath))
                        .font(.caption)
                        .foregroundStyle(Tints.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(scan.rootPath)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                  }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if m.scan != nil {
                HStack(spacing: 10) {
                    if let notice = m.snapshotNotice {
                        Text(notice).font(.caption).foregroundStyle(Tints.secondaryText)
                    } else {
                        Text("Keep a record of this scan.").font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                    Spacer()
                    if m.snapshotBusy { ProgressView().controlSize(.small) }
                    Button(m.snapshotAlreadySaved ? "snapshot saved" : "save snapshot", systemImage: m.snapshotAlreadySaved ? "checkmark" : "square.and.arrow.down") {
                        m.saveSnapshot()
                    }
                    .accessibilityLabel(m.snapshotAlreadySaved ? "Snapshot Saved" : "Save Snapshot")
                    .buttonStyle(StorageButtonStyle())
                    .disabled(m.busy || m.snapshotBusy || m.snapshotAlreadySaved)
                    .help("Save this scan’s location and top-level sizes to History on this Mac. File contents are not copied.")
                }.padding(.horizontal, 24).padding(.bottom, 10)
            }
            Divider().overlay(Tints.mint.opacity(0.18))
            Group {
                switch m.storageSection {
                case .explore: explorer
                case .developer: DeveloperView()
                case .cleanup: CleanupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var explorer: some View { StorageExplorePanel(inspector: $inspector) }
}

struct StorageExplorePanel: View {
    @EnvironmentObject var m: ExplorerModel
    @Binding var inspector: Bool
    @State private var explainingSizes = false
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 660 || geometry.size.height < 650
            if compact {
                ScrollView {
                    panel(compact: true)
                }
            } else {
                panel(compact: false)
            }
        }
    }
    private func panel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    .buttonStyle(StorageButtonStyle())
                    .disabled(m.scan == nil || m.busy)
                Button { inspector.toggle() } label: { Label("inspector", systemImage: "sidebar.right").accessibilityLabel("Inspector") }
                    .buttonStyle(StorageButtonStyle(prominent: inspector))
                    .help(inspector ? "Hide Inspector" : "Show Inspector")
                    .accessibilityAddTraits(inspector ? .isSelected : [])
              }.fixedSize()
            TextField("Filter this folder", text: $m.search)
                .textFieldStyle(.plain)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Color.black)
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
                    .background(Color.black)
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
                        .popover(isPresented: $explainingSizes) { ScrollView { SizeExplanationView(accounting: m.scanStorageAccounting, scan: m.scan).padding(22) }.frame(width: 420, height: 480).background(Color.black) }
                    Button("on disk") { m.allocated = true }.accessibilityLabel("On disk")
                        .buttonStyle(StorageButtonStyle(prominent: m.allocated))
                        .accessibilityAddTraits(m.allocated ? .isSelected : [])
                    Button("logical") { m.allocated = false }.accessibilityLabel("Logical")
                        .buttonStyle(StorageButtonStyle(prominent: !m.allocated))
                        .accessibilityAddTraits(!m.allocated ? .isSelected : [])
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let scan = m.scan, scan.nodes.indices.contains(m.focus) {
                controlsLayout {
                    Text(m.focus == 0 && m.allocated ? m.scanStorageAccounting?.summary ?? "\(StorageLabels.size(scan.nodes[m.focus], allocated: m.allocated)) in this folder" : "\(StorageLabels.size(scan.nodes[m.focus], allocated: m.allocated)) in this folder").fontWeight(.medium)
                        .help(m.scanStorageAccounting.map { $0.explanation + "\n\nCapacity measured after this scan; rescan to update." } ?? "Totals include only files reached by this scan.")
                    if !compact { Spacer() }
                    Text("Select to inspect · Option-click or M to mark · Double-click to open")
                        .foregroundStyle(Tints.secondaryText)
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Tints.secondaryText.opacity(0.18))
            StorageFreeSpaceView()
            if m.mapItems.isEmpty || ([.folders, .top, .age, .types].contains(m.mode) && m.visible.isEmpty) { StorageEmptyView("No matching items", systemImage: "folder", description: Text("Try another filter or open a different folder.")) }
            else if m.mode == .folders { folderList.frame(height: compact ? 400 : nil) }
            else { DiskMapView(compact: compact).frame(minHeight: compact && [.top, .age, .types].contains(m.mode) ? 400 : 0) }
        }.padding(compact ? 16 : 26)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var folderList: some View {
        List(m.visible) { n in
            Button { m.selected = n.id } label: {
                HStack(spacing: 14) {
                    Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill").font(.title3).foregroundStyle(Tints.forNode(n)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) { Text(StorageLabels.name(n)).font(.system(size: 15, weight: .medium)); Text(n.isDirectory ? "\(n.children.count) items" : n.modified == .distantPast || !n.modified.timeIntervalSince1970.isFinite ? "Unknown" : n.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Tints.secondaryText) }
                    Spacer()
                    Text(StorageLabels.size(n, allocated: m.allocated)).monospacedDigit().foregroundStyle(Tints.secondaryText)
                    if n.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tints.secondaryText.opacity(0.7)) }
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).simultaneousGesture(TapGesture(count: 2).onEnded { m.open(n) })
                .listRowBackground(m.selected == n.id ? Tints.mint.opacity(0.1) : Color.black)
                .contextMenu { StorageItemMenu(node: n) }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Color.black)
    }
}

struct StorageFreeSpaceView: View {
    @EnvironmentObject var m: ExplorerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Free now: \(m.volumeFree.map(DiskFormat.bytes) ?? "Unavailable") → Up to \(m.projectedFreeUpperBound.map(DiskFormat.bytes) ?? "Unavailable") after emptying Trash")
                .font(.caption).monospacedDigit().foregroundStyle(Tints.mint)
                .fixedSize(horizontal: false, vertical: true)
            Text("Staging changes nothing on disk. Shared APFS blocks and snapshots can reduce the space recovered.")
                .font(.caption2).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum Tints {
    static let electricBlue = DaddyPalette.blue
    static let mint = DaddyPalette.mint
    static let secondaryText = DaddyPalette.secondaryInk
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
                    Text(StorageLabels.size(n, allocated: m.allocated, compact: true)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().help(StorageLabels.size(n, allocated: m.allocated))
                    Divider().overlay(Tints.secondaryText.opacity(0.18))
                    metric("On disk", StorageLabels.size(n, allocated: true)); metric("Logical", StorageLabels.size(n, allocated: false)); metric("Modified", n.modified == .distantPast || !n.modified.timeIntervalSince1970.isFinite ? "Unknown" : n.modified.formatted(date: .abbreviated, time: .omitted)); metric("Contents", n.isContentsUnreadable == true ? "Not enumerated" : "\(n.children.count) immediate items\(n.isScanIncomplete == true ? " · incomplete" : "")")
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
                    CleanupFlag(category: m.cleanupCategory(n.id))
                    if let assessment = FolderArchetypes.assess(scan, folderID: n.id, category: m.cleanupCategory(n.id)) {
                        Text(assessment.explanation).font(.caption).foregroundStyle(Tints.secondaryText).textSelection(.enabled)
                    }
                    if let note = CleanupGuidance.chromeCacheNote(path: scan.url(for: n.id).path) {
                        Text(note).font(.caption).foregroundStyle(Tints.yellow)
                    }
                    Button(m.staged.contains(n.id) ? "Staged for Cleanup" : "Add to Cleanup", systemImage: "tray.and.arrow.down") { m.stage(n.id) }.buttonStyle(StorageButtonStyle(prominent: true)).disabled(m.staged.contains(n.id) || m.busy || m.monitoring || n.parent == nil)
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
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
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
            .background(Color.black)
            .buttonStyle(StorageButtonStyle())
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
    private static let image: NSImage? = Bundle.main.url(forResource: "StorageDaddy", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        if let image = Self.image { Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true) }
        else { Image(systemName: "externaldrive.fill").resizable().scaledToFit().foregroundStyle(Tints.mint).accessibilityHidden(true) }
    }
}
