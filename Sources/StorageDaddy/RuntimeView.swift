import AppKit
import DiskCore
import SaaSMakerUI
import SwiftUI
import UserNotifications

enum RuntimePresentation: String, CaseIterable, Identifiable {
    case list = "List", memoryMap = "Memory Map", cpuHeatmap = "CPU Heatmap", details = "Details"
    var id: String { rawValue }
}
enum RuntimeSort: String, CaseIterable { case cpu = "CPU", memory = "Memory", name = "Name", pid = "PID" }

@MainActor
final class RuntimeModel: ObservableObject {
    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var history = RuntimeProcessHistory()
    var frames: [RuntimeProcessHistory.Frame] { history.frames }
    @Published var grouping: RuntimeProcessGrouping = .individual
    @Published var cpuScale: RuntimeCPUScale = .oneCore
    @Published private(set) var driveHistory = DriveMonitorHistory()
    @Published private(set) var widgetDrives: [DriveCapacity] = []
    @Published private(set) var driveWarning: String?
    @Published var error: String?
    @Published var search = ""
    @Published var presentation: RuntimePresentation = .list
    @Published var sort: RuntimeSort = .cpu
    @Published var selectedID: RuntimeProcessIdentity?
    @Published var paused = false {
        didSet {
            if oldValue && !paused { history.removeAll(); Task { await sampler.reset() } }
        }
    }
    @Published var interval: Double = 2
    @Published var widgetPinned = true {
        didSet {
            UserDefaults.standard.set(widgetPinned, forKey: "runtimeWidgetPinned")
            widget?.setPinned(widgetPinned)
        }
    }
    @Published var monitoringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitoringEnabled, forKey: "driveMonitoringEnabled")
            restartDriveMonitoring()
        }
    }
    @Published var monitoringIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(monitoringIntervalMinutes, forKey: "driveMonitoringIntervalMinutes"); restartDriveMonitoring() }
    }
    @Published var monitoringRequireIdle: Bool {
        didSet { UserDefaults.standard.set(monitoringRequireIdle, forKey: "driveMonitoringRequireIdle") }
    }
    @Published var monitoringIdleMinutes: Int {
        didSet { UserDefaults.standard.set(monitoringIdleMinutes, forKey: "driveMonitoringIdleMinutes") }
    }
    @Published var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "driveMonitoringAlerts") }
    }
    @Published var alertThresholdGB: Double {
        didSet { UserDefaults.standard.set(alertThresholdGB, forKey: "driveMonitoringThresholdGB") }
    }
    @Published var alertThresholdPercent: Double {
        didSet { UserDefaults.standard.set(alertThresholdPercent, forKey: "driveMonitoringThresholdPercent") }
    }
    @Published var excludedDriveIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedDriveIDs), forKey: "driveMonitoringExcludedIDs") }
    }
    /// Root updates this from its scan state so the mini-window reports real status.
    @Published var scanStatus = "No scan running"
    private let sampler = RuntimeSampler()
    private let driveMonitor: DriveMonitor
    private var consumers = Set<String>()
    private var samplingTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var widget: RuntimeWidgetController?
    private var lastDrivePollUptime: Double?

    init() {
        let defaults = UserDefaults.standard
        widgetPinned = defaults.object(forKey: "runtimeWidgetPinned") as? Bool ?? true
        monitoringEnabled = defaults.bool(forKey: "driveMonitoringEnabled")
        monitoringIntervalMinutes = min(60, max(1, defaults.object(forKey: "driveMonitoringIntervalMinutes") as? Int ?? 1))
        monitoringRequireIdle = defaults.bool(forKey: "driveMonitoringRequireIdle")
        monitoringIdleMinutes = min(120, max(1, defaults.object(forKey: "driveMonitoringIdleMinutes") as? Int ?? 10))
        alertsEnabled = defaults.bool(forKey: "driveMonitoringAlerts")
        alertThresholdGB = defaults.object(forKey: "driveMonitoringThresholdGB") as? Double ?? 1
        alertThresholdPercent = defaults.object(forKey: "driveMonitoringThresholdPercent") as? Double ?? 1
        excludedDriveIDs = Set(defaults.stringArray(forKey: "driveMonitoringExcludedIDs") ?? [])
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        driveMonitor = DriveMonitor(storeURL: support.appendingPathComponent("StorageDaddy/drive-events.json"))
        restartDriveMonitoring()
    }

    var visibleProcesses: [RuntimeProcess] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.processes ?? []).filter { process in
            query.isEmpty || process.name.localizedCaseInsensitiveContains(query)
                || String(process.id.pid).contains(query)
                || (process.executablePath?.localizedCaseInsensitiveContains(query) ?? false)
        }.sorted { a, b in
            switch sort {
            case .cpu: if a.cpuPercent != b.cpuPercent { return (a.cpuPercent ?? -1) > (b.cpuPercent ?? -1) }
            case .memory: if a.residentBytes != b.residentBytes { return (a.residentBytes ?? 0) > (b.residentBytes ?? 0) }
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                if order != .orderedSame { return order == .orderedAscending }
            case .pid: break
            }
            return a.id.pid < b.id.pid
        }
    }
    var visibleGroups: [RuntimeProcessGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeProcessGroups.build(snapshot?.processes ?? [], grouping: grouping).filter { group in
            query.isEmpty || group.name.localizedCaseInsensitiveContains(query) || group.members.contains { process in
                process.name.localizedCaseInsensitiveContains(query) || String(process.id.pid).contains(query)
                    || (process.executablePath?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }.sorted { a, b in
            switch sort {
            case .cpu: if a.cpuPercent != b.cpuPercent { return (a.cpuPercent ?? -1) > (b.cpuPercent ?? -1) }
            case .memory: if a.residentBytes != b.residentBytes { return (a.residentBytes ?? 0) > (b.residentBytes ?? 0) }
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                if order != .orderedSame { return order == .orderedAscending }
            case .pid: break
            }
            return a.representative.id.pid < b.representative.id.pid
        }
    }
    func displayCPU(_ value: Double?) -> Double? {
        cpuScale.processPercent(value, logicalCoreCount: snapshot?.logicalCoreCount ?? 0)
    }
    func historyValues(for identity: RuntimeProcessIdentity, metric: RuntimeProcessHistory.Metric) -> [Double?] {
        history.values(for: RuntimeProcessGroups.processID(identity), metric: metric, scale: cpuScale)
    }
    var selectedProcess: RuntimeProcess? {
        guard let selectedID else { return nil }
        return snapshot?.processes.first { $0.id == selectedID }
    }
    var driveSettings: DriveMonitorSettings {
        let gb = alertThresholdGB.isFinite ? min(1_000_000, max(0.01, alertThresholdGB)) : 1
        return DriveMonitorSettings(enabled: monitoringEnabled, thresholdBytes: Int64(gb * 1_000_000_000),
            thresholdPercent: alertThresholdPercent, excludedDriveIDs: excludedDriveIDs)
    }
    func startConsumer(_ name: String) {
        consumers.insert(name)
        guard samplingTask == nil else { return }
        history.removeAll()
        samplingTask = Task { [weak self] in
            guard let self else { return }
            await sampler.reset()
            while !Task.isCancelled {
                if !paused { await refresh() }
                // Keep the visible widget's capacity live even when persistent
                // drive monitoring and event recording are turned off.
                if consumers.contains("widget"), ProcessInfo.processInfo.systemUptime - (lastDrivePollUptime ?? 0) >= 10 {
                    await refreshWidgetDrives()
                }
                do { try await Task.sleep(for: .seconds(max(1, min(10, interval)))) }
                catch { break }
            }
        }
    }
    func stopConsumer(_ name: String) {
        consumers.remove(name)
        if consumers.isEmpty { samplingTask?.cancel(); samplingTask = nil }
    }
    func refresh() async {
        let value = await sampler.sample()
        guard !Task.isCancelled else { return }
        snapshot = value
        history.append(date: value.timestamp, logicalCoreCount: value.logicalCoreCount, processes: value.processes)
    }
    func terminate(_ process: RuntimeProcess, force: Bool) {
        do { try RuntimeSampler.sendSignal(to: process, force: force) }
        catch { self.error = error.localizedDescription }
        Task { await refresh() }
    }
    func showWidget() {
        if widget == nil { widget = RuntimeWidgetController(model: self) }
        widget?.show()
    }
    func requestAlerts(_ enabled: Bool) {
        guard enabled else { alertsEnabled = false; return }
        Task {
            do { alertsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            catch { alertsEnabled = false; self.error = "Notifications could not be enabled. Check System Settings."
            }
        }
    }
    func refreshDrives() async {
        let result = await driveMonitor.sample(settings: driveSettings)
        guard !Task.isCancelled else { return }
        driveHistory = result.history; driveWarning = result.persistenceError
        widgetDrives = result.history.latest
        if alertsEnabled && monitoringEnabled {
            for event in result.newEvents where event.kind == .spaceDropped || event.pressure != .normal {
                let content = UNMutableNotificationContent()
                content.title = "\(event.driveName): \(runtimeBytes(event.freeBytes)) free"
                content.body = event.kind == .spaceDropped
                    ? "Available space dropped by \(runtimeBytes(event.droppedBytes)). Review drive activity in StorageDaddy."
                    : "Free space is now \(event.pressure.rawValue). Review your storage before choosing cleanup."
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
            }
        }
    }
    func refreshWidgetDrives() async {
        let readings = await Task.detached(priority: .utility) { DriveMonitor.readCapacities() }.value
        guard !Task.isCancelled else { return }
        widgetDrives = readings
        lastDrivePollUptime = ProcessInfo.processInfo.systemUptime
    }
    private func restartDriveMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await driveMonitor.resetBaselines()
            await refreshDrives()
            while monitoringEnabled && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Double(min(60, max(1, monitoringIntervalMinutes))) * 60)) } catch { break }
                if SystemIdlePolicy.allows(requireIdle: monitoringRequireIdle, minutes: monitoringIdleMinutes, idleSeconds: SystemIdlePolicy.idleSeconds) {
                    await refreshDrives()
                }
            }
        }
    }
}

struct RuntimeView: View {
    @ObservedObject var model: RuntimeModel
    @State private var pendingAction: RuntimePendingAction?
    @State private var expandedGroups: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    SMSectionHeader("Processes", size: 28)
                    Text("Live CPU and memory on this Mac. " + model.cpuScale.explanation)
                        .foregroundStyle(Tints.secondaryText)
                }
                Spacer()
                Button("System Widget", systemImage: "macwindow", action: model.showWidget)
                    .buttonStyle(StorageButtonStyle())
            }
            RuntimeSummary(model: model)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { presentationPicker; processFilters }
                VStack(alignment: .leading, spacing: 12) { presentationPicker; processFilters }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { groupingPicker; cpuScalePicker; groupingNote }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) { groupingPicker; cpuScalePicker }
                    groupingNote
                }
            }
            Group {
                if model.snapshot == nil {
                    ProgressView("Reading processes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch model.presentation {
                    case .list: processList
                    case .memoryMap: RuntimeMemoryMap(model: model)
                    case .cpuHeatmap: RuntimeCPUHeatmap(model: model)
                    case .details: processDetails
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("\(model.visibleGroups.count) \(model.grouping == .individual ? "processes" : "groups") shown · \(model.snapshot?.processes.count ?? 0) processes · \(model.snapshot?.inaccessibleProcessCount ?? 0) inaccessible")
                Spacer()
                Picker("Refresh", selection: $model.interval) {
                    Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
                }.frame(width: 150)
            }.font(.caption).foregroundStyle(Tints.secondaryText)
            Text("GPU / VRAM and per-process disk I/O are unavailable in this view. Disk I/O above covers physical storage drivers.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .padding(24).background(AppColors.canvas).foregroundStyle(AppColors.ink).tint(Tints.mint)
        .background(RuntimeVisibilityObserver(model: model).frame(width: 0, height: 0))
        .onChange(of: model.grouping) { _, _ in expandedGroups.removeAll() }
        .confirmationDialog(pendingAction.map { "\($0.force ? "Force quit" : "End") \($0.process.name) (PID \($0.process.id.pid))?" } ?? "End process?",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let pendingAction {
                Button(pendingAction.force ? "Force Quit Process" : "End Process", role: .destructive) {
                    model.terminate(pendingAction.process, force: pendingAction.force)
                    self.pendingAction = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.force == true ? "Unsaved work can be lost. The process identity is checked again before SIGKILL is sent."
                 : "SIGTERM asks the process to exit. Unsaved work may be lost; the process may choose to keep running.")
        }
        .alert("Process action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var presentationPicker: some View {
        Picker("View", selection: $model.presentation) {
            ForEach(RuntimePresentation.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).frame(minWidth: 350, maxWidth: 430)
    }
    private var processFilters: some View {
        HStack(spacing: 12) {
            TextField("Search name, PID or path", text: $model.search)
                .textFieldStyle(.roundedBorder).frame(minWidth: 160)
            Picker("Sort", selection: $model.sort) {
                ForEach(RuntimeSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 120)
            Button(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill") { model.paused.toggle() }
                .buttonStyle(StorageButtonStyle())
        }
    }
    private var groupingPicker: some View {
        Picker("Group", selection: $model.grouping) {
            ForEach(RuntimeProcessGrouping.allCases) { Text($0.rawValue).tag($0) }
        }.frame(width: 205)
    }
    private var cpuScalePicker: some View {
        Picker("CPU scale", selection: $model.cpuScale) {
            ForEach(RuntimeCPUScale.allCases) { Text($0.rawValue).tag($0) }
        }.frame(width: 205)
    }
    private var groupingNote: some View {
        Text(model.grouping == .individual ? "Each row keeps its own PID and start identity."
             : model.grouping == .parentTree ? "Expand a parent to inspect its child processes."
             : "App bundles include their helpers. Expand to inspect each process.")
            .font(.caption2).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
    private var processList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.grouping == .individual ? "Process" : "Group / process"); Spacer()
                Text("CPU history").frame(width: 88)
                Text("PID").frame(width: 60, alignment: .trailing)
                Text("CPU").frame(width: 78, alignment: .trailing)
                Text("Memory").frame(width: 100, alignment: .trailing)
            }.font(.caption).foregroundStyle(Tints.secondaryText).padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleGroups) { group in
                        groupRow(group)
                        if group.members.count > 1, expandedGroups.contains(group.id) {
                            ForEach(group.members) { process in individualRow(process).padding(.leading, 30) }
                        }
                    }
                }
            }
            if model.visibleGroups.isEmpty { Text("No matching processes").foregroundStyle(Tints.secondaryText).padding(30) }
        }
    }
    private func groupRow(_ group: RuntimeProcessGroup) -> some View {
        HStack(spacing: 4) {
            if group.members.count > 1 {
                Button {
                    if !expandedGroups.insert(group.id).inserted { expandedGroups.remove(group.id) }
                } label: {
                    Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right").font(.caption)
                        .frame(width: 20, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel((expandedGroups.contains(group.id) ? "Collapse " : "Expand ") + group.name)
            } else { Color.clear.frame(width: 20) }
            Button { showDetails(group.representative) } label: {
                HStack(spacing: 10) {
                    RuntimeProcessIcon(process: group.representative).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name).fontWeight(.medium).lineLimit(1)
                        Text(group.members.count > 1 ? "\(group.members.count) processes · CPU and RSS combined" : group.representative.executablePath ?? "Executable path unavailable")
                            .font(.caption2).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    RuntimeTrendLine(values: model.history.values(for: group.id, metric: .cpu, scale: model.cpuScale), minimumCeiling: 100)
                        .frame(width: 88, height: 24).accessibilityLabel("CPU history for " + group.name)
                    Text(group.members.count > 1 ? "—" : String(group.representative.id.pid)).frame(width: 60, alignment: .trailing)
                    Text(runtimePercent(model.displayCPU(group.cpuPercent))).frame(width: 78, alignment: .trailing)
                    Text(group.residentBytes.map(runtimeBytes) ?? "—").frame(width: 100, alignment: .trailing)
                }.monospacedDigit().padding(10).contentShape(Rectangle())
                    .background(model.selectedID == group.representative.id ? Tints.mint.opacity(0.14) : AppColors.ink.opacity(0.025))
            }.buttonStyle(.plain).help(group.members.count > 1 ? "Expand to inspect every process. Click to show the representative process." : "Show process details")
                .contextMenu {
                    Button("Show Process Details") { showDetails(group.representative) }
                    if group.members.count == 1 { processActions(group.representative) }
                }
        }
    }
    private func individualRow(_ process: RuntimeProcess) -> some View {
        Button { showDetails(process) } label: {
            HStack(spacing: 10) {
                RuntimeProcessIcon(process: process).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).lineLimit(1)
                    Text(process.executablePath ?? "Executable path unavailable")
                        .font(.caption2).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                RuntimeTrendLine(values: model.historyValues(for: process.id, metric: .cpu), minimumCeiling: 100)
                    .frame(width: 88, height: 24).accessibilityLabel("CPU history for " + process.name)
                Text(String(process.id.pid)).frame(width: 60, alignment: .trailing)
                Text(runtimePercent(model.displayCPU(process.cpuPercent))).frame(width: 78, alignment: .trailing)
                Text(process.residentBytes.map(runtimeBytes) ?? "—").frame(width: 100, alignment: .trailing)
            }.monospacedDigit().padding(10).contentShape(Rectangle())
                .background(model.selectedID == process.id ? Tints.mint.opacity(0.14) : AppColors.ink.opacity(0.025))
        }.buttonStyle(.plain).contextMenu {
            Button("Show Details") { showDetails(process) }
            processActions(process)
        }
    }
    @ViewBuilder private func processActions(_ process: RuntimeProcess) -> some View {
        if let path = process.executablePath {
            Button("Reveal Executable") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        Divider()
        Button("End Process…") { pendingAction = RuntimePendingAction(process: process, force: false) }.disabled(!process.mayTerminate)
        Button("Force Quit Process…") { pendingAction = RuntimePendingAction(process: process, force: true) }.disabled(!process.mayTerminate)
    }
    private func showDetails(_ process: RuntimeProcess) { model.selectedID = process.id; model.presentation = .details }
    private var processDetails: some View {
        Group {
            if let process = model.selectedProcess {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 16) {
                            RuntimeProcessIcon(process: process).frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(process.name).font(.title2.weight(.semibold))
                                Text("PID \(process.id.pid) · parent \(process.parentPID) · user \(process.uid)").foregroundStyle(Tints.secondaryText)
                            }
                        }
                        HStack(spacing: 40) {
                            runtimeMetric("CPU", value: runtimePercent(model.displayCPU(process.cpuPercent)), hint: model.cpuScale == .oneCore ? "Interval · one core = 100%" : "Interval · whole system = 100%")
                            runtimeMetric("Resident memory", value: process.residentBytes.map(runtimeBytes) ?? "—", hint: "RSS can include shared pages")
                        }
                        RuntimeTrendChart(title: "CPU history", values: model.historyValues(for: process.id, metric: .cpu),
                            currentValue: runtimePercent(model.displayCPU(process.cpuPercent)), minimumCeiling: 100)
                        RuntimeTrendChart(title: "Resident memory history", values: model.historyValues(for: process.id, metric: .residentMemory),
                            currentValue: process.residentBytes.map(runtimeBytes) ?? "—", minimumCeiling: 1)
                        Text("Last \(model.frames.count) samples · gaps mean unavailable · PID and start time keep reused PIDs separate.")
                            .font(.caption2).foregroundStyle(Tints.secondaryText)
                        LabeledContent("Executable", value: process.executablePath ?? "Unavailable").textSelection(.enabled)
                        LabeledContent("Started", value: Date(timeIntervalSince1970: Double(process.id.started) / 1_000_000).formatted())
                        Text("GPU / VRAM: unavailable on macOS\nPer-process disk I/O: unavailable in this view")
                            .foregroundStyle(Tints.secondaryText).font(.callout)
                        HStack(spacing: 12) {
                            if let path = process.executablePath {
                                Button("Reveal Executable", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    .buttonStyle(StorageButtonStyle())
                            }
                            Button("End Process…") { pendingAction = RuntimePendingAction(process: process, force: false) }
                                .buttonStyle(StorageButtonStyle()).disabled(!process.mayTerminate)
                            Button("Force Quit…") { pendingAction = RuntimePendingAction(process: process, force: true) }
                                .buttonStyle(StorageButtonStyle()).disabled(!process.mayTerminate)
                        }
                        if !process.mayTerminate { Text("System processes, other users' processes and StorageDaddy itself cannot be ended here.").font(.caption).foregroundStyle(Tints.secondaryText) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(Tints.mint)
                    Text(model.selectedID == nil ? "Choose a process from the list or memory map." : "This process has exited. Choose another process.")
                    Button("Show Process List") { model.presentation = .list }.buttonStyle(StorageButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct RuntimeTrendLine: View {
    let values: [Double?]
    let minimumCeiling: Double
    var body: some View {
        Canvas { context, size in
            let inset = 2.0
            let segments = RuntimeTrendSegments.make(values: values, width: max(0, size.width - inset * 2),
                height: max(0, size.height - inset * 2), minimumCeiling: minimumCeiling)
            for segment in segments {
                if segment.count == 1, let point = segment.first {
                    context.fill(Path(ellipseIn: CGRect(x: point.x + inset - 1.5, y: point.y + inset - 1.5, width: 3, height: 3)), with: .color(Tints.mint))
                } else {
                    var path = Path()
                    for (index, point) in segment.enumerated() {
                        let location = CGPoint(x: point.x + inset, y: point.y + inset)
                        if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                    }
                    context.stroke(path, with: .color(Tints.mint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }.background(Tints.mint.opacity(0.035))
    }
}

private struct RuntimeTrendChart: View {
    let title: String
    let values: [Double?]
    let currentValue: String
    let minimumCeiling: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.caption).foregroundStyle(Tints.secondaryText); Spacer(); Text(currentValue).font(.caption).monospacedDigit() }
            RuntimeTrendLine(values: values, minimumCeiling: minimumCeiling).frame(height: 80)
                .accessibilityLabel(title).accessibilityValue(currentValue)
        }.padding(12).overlay(Rectangle().stroke(Tints.mint.opacity(0.15)))
    }
}

private struct RuntimePendingAction { let process: RuntimeProcess; let force: Bool }

private struct RuntimeSummary: View {
    @ObservedObject var model: RuntimeModel
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            runtimeMetric("CPU", value: runtimePercent(model.snapshot?.cpuPercent), hint: "Overall · \(model.snapshot?.logicalCoreCount ?? 0) cores")
            runtimeMetric("Memory", value: model.snapshot?.memory.map { runtimeBytes($0.usedBytes) } ?? "—", hint: "Active + wired + compressed")
            runtimeMetric("Swap", value: model.snapshot?.memory?.swapUsedBytes.map(runtimeBytes) ?? "—", hint: "Currently allocated")
            runtimeMetric("Disk read", value: runtimeRate(model.snapshot?.diskIO.read), hint: "Aggregate drivers")
            runtimeMetric("Disk write", value: runtimeRate(model.snapshot?.diskIO.write), hint: "Aggregate drivers")
            Spacer(minLength: 0)
        }.padding(18).background(Tints.mint.opacity(0.055)).overlay(Rectangle().stroke(Tints.mint.opacity(0.2)))
    }
}

@MainActor private func runtimeMetric(_ title: String, value: String, hint: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.caption).foregroundStyle(Tints.secondaryText)
        Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        Text(hint).font(.caption2).foregroundStyle(Tints.secondaryText)
    }
}
private func runtimeBytes<T: BinaryInteger>(_ value: T) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
}
private func runtimePercent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
private func runtimeRate(_ value: StorageDashboardMetrics.Rate?) -> String {
    guard case let .measured(bytes) = value else { return "—" }
    return runtimeBytes(Int64(min(Double(Int64.max), max(0, bytes)))) + "/s"
}

@MainActor private struct RuntimeProcessIcon: View {
    let process: RuntimeProcess
    var body: some View {
        if let path = process.executablePath {
            let iconPath = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath)).resizable().interpolation(.high).scaledToFit()
        } else { Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(Tints.mint) }
    }
}

private struct RuntimeMemoryMap: View {
    @ObservedObject var model: RuntimeModel
    private var groups: [RuntimeProcessGroup] {
        model.visibleGroups.filter { ($0.residentBytes ?? 0) > 0 }.sorted { ($0.residentBytes ?? 0) > ($1.residentBytes ?? 0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Area represents resident memory. Shared pages can appear in more than one process; this is not a sum of physical RAM.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            GeometryReader { geometry in
                let visible = Array(groups.prefix(80))
                let remainder = groups.dropFirst(80).reduce(0.0) { $0 + Double($1.residentBytes ?? 0) }
                let weights = visible.map { Double($0.residentBytes ?? 0) } + (remainder > 0 ? [remainder] : [])
                let rects = runtimeTreemap(weights: weights, in: CGRect(origin: .zero, size: geometry.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                        if index < visible.count {
                            let group = visible[index]
                            let process = group.representative
                            Button { model.selectedID = process.id; model.presentation = .details } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if rect.width > 65 && rect.height > 35 {
                                        Text(group.name).font(.caption.weight(.semibold)).lineLimit(2)
                                        if rect.height > 60 { Text(group.residentBytes.map(runtimeBytes) ?? "—").font(.caption2).monospacedDigit() }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2), alignment: .topLeading)
                                    .background([Tints.mint, Tints.electricBlue, Tints.cyan, Tints.coral][index % 4].opacity(0.28 + Double(index % 3) * 0.12))
                                    .contentShape(Rectangle()).clipped()
                            }.buttonStyle(.plain).position(x: rect.midX, y: rect.midY)
                                .help("\(group.name) · \(group.members.count) processes · \(group.residentBytes.map(runtimeBytes) ?? "—")")
                        } else {
                            Text("Other processes").font(.caption).lineLimit(2).padding(8)
                                .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
                                .background(AppColors.ink.opacity(0.1)).clipped().position(x: rect.midX, y: rect.midY)
                        }
                    }
                }.clipped()
            }
            if groups.isEmpty { Text("No resident-memory samples match this search.").foregroundStyle(Tints.secondaryText) }
        }
    }
}

/// Squarifies the largest-first weights. The remainder tile keeps the whole
/// population in the denominator when only 80 process labels are displayed.
private func runtimeTreemap(weights: [Double], in bounds: CGRect) -> [CGRect] {
    guard bounds.width > 0, bounds.height > 0 else { return [] }
    let total = weights.reduce(0, +)
    guard total > 0 else { return [] }
    let areas = weights.map { max(0, $0) / total * bounds.width * bounds.height }
    var remaining = bounds, row: [Int] = [], result = [CGRect](repeating: .zero, count: weights.count)
    func worst(_ indices: [Int], side: Double) -> Double {
        guard let smallest = indices.map({ areas[$0] }).min(), let largest = indices.map({ areas[$0] }).max(), smallest > 0, side > 0 else { return .infinity }
        let sum = indices.reduce(0.0) { $0 + areas[$1] }
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }
    func place(_ indices: [Int]) {
        let sum = indices.reduce(0.0) { $0 + areas[$1] }
        if remaining.width >= remaining.height {
            let width = min(remaining.width, sum / max(1, remaining.height)); var y = remaining.minY
            for index in indices { let h = areas[index] / max(0.0001, width); result[index] = CGRect(x: remaining.minX, y: y, width: width, height: h); y += h }
            remaining.origin.x += width; remaining.size.width = max(0, remaining.width - width)
        } else {
            let height = min(remaining.height, sum / max(1, remaining.width)); var x = remaining.minX
            for index in indices { let w = areas[index] / max(0.0001, height); result[index] = CGRect(x: x, y: remaining.minY, width: w, height: height); x += w }
            remaining.origin.y += height; remaining.size.height = max(0, remaining.height - height)
        }
    }
    for index in areas.indices {
        let side = min(remaining.width, remaining.height)
        if !row.isEmpty && worst(row + [index], side: side) > worst(row, side: side) { place(row); row = [] }
        row.append(index)
    }
    if !row.isEmpty { place(row) }
    return result
}

private struct RuntimeCPUHeatmap: View {
    @ObservedObject var model: RuntimeModel
    private var rows: [RuntimeProcessGroup] {
        let peaks = Dictionary(uniqueKeysWithValues: model.visibleGroups.map { group in
            (group.id, model.history.values(for: group.id, metric: .cpu, scale: model.cpuScale).compactMap { $0 }.max() ?? 0)
        })
        return Array(model.visibleGroups.sorted { a, b in
            let left = peaks[a.id] ?? 0, right = peaks[b.id] ?? 0
            return left == right ? a.representative.id.pid < b.representative.id.pid : left > right
        }.prefix(24))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Recent CPU · 24 \(model.grouping == .individual ? "processes" : "groups") with the highest sampled peaks"); Spacer(); Text("Now →") }
                .font(.caption).foregroundStyle(Tints.secondaryText)
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { group in
                            Button { model.selectedID = group.representative.id; model.presentation = .details } label: {
                                Text(group.name).font(.caption).lineLimit(1).frame(width: 150, height: 23, alignment: .leading)
                            }.buttonStyle(.plain).help("\(group.name) · \(group.members.count) processes")
                        }
                    }
                    Canvas { context, size in
                        let cellWidth = size.width / 120
                        let start = 120 - model.frames.count
                        for (row, group) in rows.enumerated() {
                            let values = model.history.values(for: group.id, metric: .cpu, scale: model.cpuScale)
                            for (column, value) in values.enumerated() {
                                let intensity = value.map { min(1, max(0, $0) / 100) } ?? 0
                                let color = value == nil ? AppColors.ink.opacity(0.025) : Tints.mint.opacity(0.06 + intensity * 0.94)
                                let rect = CGRect(x: Double(start + column) * cellWidth, y: Double(row) * 23, width: max(1, cellWidth - 1), height: 21)
                                context.fill(Path(rect), with: .color(color))
                            }
                        }
                    }.frame(height: CGFloat(rows.count * 23))
                }
            }
            HStack { Text(model.frames.first?.date.formatted(date: .omitted, time: .standard) ?? "Waiting for samples")
                Spacer(); Text(model.cpuScale == .oneCore ? "Dark = idle · mint = one core · blank = unavailable" : "Dark = idle · mint = whole system · blank = unavailable") }
                .font(.caption2).foregroundStyle(Tints.secondaryText)
        }
    }
}

struct DriveMonitoringView: View {
    @ObservedObject var model: RuntimeModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SMSectionHeader("Drive Monitoring", size: 28)
                Text("Watch free space across local drives without scanning file contents. Events stay on this Mac.")
                    .foregroundStyle(Tints.secondaryText)
                Toggle("Monitor free space", isOn: $model.monitoringEnabled).tint(Tints.mint)
                Picker("Check frequency", selection: $model.monitoringIntervalMinutes) {
                    ForEach([1, 5, 10, 15, 30, 60], id: \.self) { Text("Every \($0) minutes").tag($0) }
                }.frame(maxWidth: 320).disabled(!model.monitoringEnabled)
                Toggle("Only poll when this Mac is idle", isOn: $model.monitoringRequireIdle).disabled(!model.monitoringEnabled)
                if model.monitoringRequireIdle {
                    Stepper("Idle for \(model.monitoringIdleMinutes) minutes", value: $model.monitoringIdleMinutes, in: 1...120)
                }
                Toggle("Notify me when available space drops", isOn: Binding(get: { model.alertsEnabled }, set: model.requestAlerts))
                    .disabled(!model.monitoringEnabled)
                HStack {
                    Text("Alert after a drop of")
                    TextField("GB", value: $model.alertThresholdGB, format: .number).frame(width: 70)
                    Text("GB or")
                    TextField("Percent", value: $model.alertThresholdPercent, format: .number).frame(width: 60)
                    Text("% of capacity")
                }.textFieldStyle(.roundedBorder)
                Text("Small drops accumulate until a threshold is reached. An increase or an alert starts a new baseline.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                if let warning = model.driveWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow) }
                Divider()
                ForEach(model.driveHistory.latest) { drive in
                    HStack(spacing: 18) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(drive.pressure == .normal ? Tints.mint : Tints.coral)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(drive.name).font(.headline)
                            Text("\(runtimeBytes(drive.freeBytes)) free of \(runtimeBytes(drive.totalBytes)) · \(Int(drive.freeRatio * 100))% free")
                                .font(.caption).foregroundStyle(Tints.secondaryText)
                            if !drive.monitoringIdentityVerified {
                                Text("Volume identity unavailable · alerts paused").font(.caption2).foregroundStyle(Tints.yellow)
                            }
                            ProgressView(value: 1 - drive.freeRatio).tint(drive.pressure == .normal ? Tints.mint : Tints.coral)
                        }
                        Spacer()
                        Toggle("Monitor", isOn: Binding(get: { !model.excludedDriveIDs.contains(drive.id) }, set: { enabled in
                            if enabled { model.excludedDriveIDs.remove(drive.id) } else { model.excludedDriveIDs.insert(drive.id) }
                        })).fixedSize().disabled(!model.monitoringEnabled || !drive.monitoringIdentityVerified)
                    }.padding(.vertical, 8)
                }
                HStack { Text("Recent events").font(.title3.weight(.semibold)); Spacer(); Button("Refresh") { Task { await model.refreshDrives() } }.buttonStyle(StorageButtonStyle()) }
                if model.driveHistory.events.isEmpty { Text("No space-drop events recorded yet.").foregroundStyle(Tints.secondaryText) }
                ForEach(model.driveHistory.events.reversed()) { event in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.driveName).font(.headline)
                            Text(event.kind == .spaceDropped ? "Available space dropped by \(runtimeBytes(event.droppedBytes))" : "Free-space pressure changed to \(event.pressure.rawValue)")
                            Text("\(runtimeBytes(event.freeBytes)) free").font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        Spacer(); Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Tints.secondaryText)
                    }.padding(.vertical, 8)
                }
            }.padding(24)
        }.foregroundStyle(AppColors.ink).background(AppColors.canvas).task { await model.refreshDrives() }
    }
}

@MainActor
private final class RuntimeWidgetController: NSObject, NSWindowDelegate {
    private weak var model: RuntimeModel?
    private var panel: NSPanel?
    init(model: RuntimeModel) { self.model = model }
    func show() {
        guard let model else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 440, height: 480),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "StorageDaddy · System"
            panel.minSize = NSSize(width: 360, height: 440)
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .black
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: RuntimeWidgetView(model: model))
            panel.delegate = self
            _ = panel.setFrameAutosaveName("storagedaddy.system-widget")
            self.panel = panel
            setPinned(model.widgetPinned)
        }
        model.startConsumer("widget")
        panel?.orderFrontRegardless()
    }
    func setPinned(_ pinned: Bool) { panel?.level = pinned ? .floating : .normal }
    func windowWillClose(_ notification: Notification) { model?.stopConsumer("widget") }
    func windowDidMiniaturize(_ notification: Notification) { model?.stopConsumer("widget") }
    func windowDidDeminiaturize(_ notification: Notification) { model?.startConsumer("widget") }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if let panel, panel.isVisible, !panel.isMiniaturized,
           panel.occlusionState.contains(.visible), !NSApplication.shared.isHidden {
            model?.startConsumer("widget")
        } else { model?.stopConsumer("widget") }
    }
}

private struct RuntimeWidgetView: View {
    @ObservedObject var model: RuntimeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System").font(.headline)
                Spacer()
                Button(model.widgetPinned ? "Unpin" : "Pin", systemImage: model.widgetPinned ? "pin.fill" : "pin") { model.widgetPinned.toggle() }
                    .buttonStyle(StorageButtonStyle())
            }
            HStack(spacing: 30) {
                runtimeMetric("CPU", value: runtimePercent(model.snapshot?.cpuPercent), hint: "Overall")
                runtimeMetric("Memory", value: model.snapshot?.memory.map { runtimeBytes($0.usedBytes) } ?? "—", hint: "Active + wired + compressed")
            }
            HStack(spacing: 30) {
                runtimeMetric("Read", value: runtimeRate(model.snapshot?.diskIO.read), hint: "Aggregate drivers")
                runtimeMetric("Write", value: runtimeRate(model.snapshot?.diskIO.write), hint: "Aggregate drivers")
            }
            Divider()
            ForEach(Array(model.widgetDrives.prefix(4))) { drive in
                HStack { Text(drive.name).lineLimit(1); Spacer(); Text(runtimeBytes(drive.freeBytes) + " free").monospacedDigit() }
                    .font(.caption).foregroundStyle(drive.pressure == .normal ? Tints.secondaryText : Tints.coral)
            }
            if model.widgetDrives.count > 4 {
                Text("+ \(model.widgetDrives.count - 4) more drives in Drive Monitoring").font(.caption2).foregroundStyle(Tints.secondaryText)
            }
            Text(model.scanStatus).font(.caption).foregroundStyle(Tints.mint).lineLimit(2)
            if model.paused { Text("Process sampling paused").font(.caption2).foregroundStyle(Tints.yellow) }
            Text("GPU / per-process disk I/O unavailable on macOS").font(.caption2).foregroundStyle(Tints.secondaryText)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(AppColors.ink).background(AppColors.canvas).preferredColorScheme(.dark).tint(Tints.mint)
            .task { await model.refreshWidgetDrives() }
    }
}
