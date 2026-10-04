import SwiftUI
import AppKit
import DiskCore

@main
struct DiskBuddyApp: App {
    @NSApplicationDelegateAdaptor(StorageDaddyAppDelegate.self) private var appDelegate
    @StateObject private var model = ExplorerModel()
    @StateObject private var updates = AppUpdates()
    var body: some Scene {
        WindowGroup("storagedaddy") { ExplorerView().environmentObject(model).frame(minWidth: 880, minHeight: 600).onAppear { updates.start(model: model) } }
            .defaultSize(width: 1320, height: 850)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About storagedaddy") { model.showAbout = true }
                }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…", action: updates.check).disabled(!updates.canCheck || !updates.isIdle)
                    Toggle("Automatically Check for Updates", isOn: $updates.automaticallyChecks)
                    if updates.waitingForIdle { Text("Update waiting for current work to finish") }
                    Divider()

                    Button("Getting Started…") { model.showWelcome = true }.disabled(model.busy)
                    Button("Acknowledgments…") { model.workspace = .acknowledgments; model.showWelcome = false }
                }
                CommandGroup(after: .newItem) {
                    Button("Scan Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                    Button("Rescan") { model.rescan() }.keyboardShortcut("r").disabled(model.scan == nil || model.busy)
                    Button("Cancel Scan") { model.cancel() }.keyboardShortcut(".").disabled(!model.busy)
                }
            }
        Settings {
            StorageSettingsView(updates: updates).environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor final class StorageDaddyAppDelegate: NSObject, NSApplicationDelegate {
    private var health: NativeAppHealth?
    private var awaitingHealthClose = false
    static let brandIcon: NSImage? = Bundle.main.url(forResource: "StorageDaddy", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    static func applyIcon() {
        guard let icon = brandIcon else { return }
        // Sparkle reads the named application icon for its update and progress windows.
        if let previous = NSImage(named: NSImage.applicationIconName), previous !== icon {
            _ = previous.setName(nil)
        }
        _ = icon.setName(NSImage.applicationIconName)
        NSApplication.shared.applicationIconImage = icon
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyIcon()
        health = NativeAppHealth(publicKey: UserDefaults.standard.string(forKey: NativeAppHealth.preferenceKey))
        health?.setActive(NSApplication.shared.isActive)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.applyIcon()
        health?.setActive(true)
    }
    func applicationDidResignActive(_ notification: Notification) { health?.setActive(false) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let health, health.isEnabled else { return .terminateNow }
        guard !awaitingHealthClose else { return .terminateLater }
        awaitingHealthClose = true
        Task {
            await health.close()
            finishHealthTermination(sender)
        }
        // A stalled transport must not prevent quitting. Delivery at process
        // termination remains best effort, even though close is invoked.
        Task {
            try? await Task.sleep(for: .seconds(3))
            finishHealthTermination(sender)
        }
        return .terminateLater
    }
    private func finishHealthTermination(_ sender: NSApplication) {
        guard awaitingHealthClose else { return }
        awaitingHealthClose = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}

enum Workspace: String, CaseIterable, Identifiable {
    case aiSessions = "AI Sessions", developer = "Developer Insights", explore = "Explore", applications = "Applications", snapshots = "Snapshots", duplicates = "Duplicates", projects = "Projects", appData = "App Data", cleanup = "Cleanup", acknowledgments = "Acknowledgments", dashboard = "Dashboard"
    var id: String { rawValue }
    var title: String { switch self { case .explore: "Storage"; case .cleanup: "Review Cleanup"; case .snapshots: "History"; default: rawValue } }
    var requiresScan: Bool { [.developer, .cleanup, .duplicates, .projects, .appData].contains(self) }
    var icon: String { switch self { case .aiSessions: "bubble.left.and.text.bubble.right.fill"; case .developer: "terminal"; case .explore: "internaldrive.fill"; case .applications: "app.badge"; case .snapshots: "clock.arrow.circlepath"; case .duplicates: "doc.on.doc"; case .projects: "folder.badge.gearshape"; case .appData: "questionmark.folder"; case .cleanup: "trash"; case .acknowledgments: "heart.text.square"; case .dashboard: "speedometer" } }
}

enum StorageSection: String, CaseIterable, Identifiable {
    case explore = "Explore"
    case developer = "Developer Insights"
    case cleanup = "Cleanup"
    var id: String { rawValue }
    var icon: String { switch self { case .explore: "square.grid.2x2"; case .developer: "terminal"; case .cleanup: "trash" } }
}
enum MapMode: String, CaseIterable, Identifiable {
    case folders = "Folders", sunburst = "Sunburst", flame = "Flame", bubbles = "Bubbles", mindMap = "Mind Map", top = "Top Sizes", age = "Age Map", types = "File Types", treemap = "Treemap"
    var id: String { rawValue }
    var icon: String { switch self { case .folders: "folder"; case .sunburst: "circle.dotted.circle"; case .flame: "chart.bar.xaxis"; case .bubbles: "circle.grid.3x3"; case .mindMap: "point.3.connected.trianglepath.dotted"; case .top: "chart.bar.fill"; case .age: "calendar"; case .types: "tag"; case .treemap: "rectangle.split.3x3" } }
}
enum MapMeasure: String, CaseIterable, Identifiable {
    case bytes = "Bytes", files = "File entries"
    var id: String { rawValue }
}

/// QDirStat-style kind buckets: a coarse answer to "what sort of data is
/// this" that an extension table alone scatters across hundreds of rows.
enum FileKind: String, CaseIterable, Sendable {
    case archives = "Archives"
    case diskImages = "Disk images"
    case installers = "Installers"
    case media = "Media"
    case documents = "Documents"
    case code = "Code"
    case data = "Data"
    case binaries = "Binaries"
    case other = "Other"

    init(ext: String) {
        switch ext {
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4", "lzma", "cab", "war", "jar": self = .archives
        case "dmg", "iso", "img", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "sparseimage": self = .diskImages
        case "pkg", "mpkg", "xip", "ipsw": self = .installers
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "mp3", "wav", "flac", "aiff", "aif", "m4a", "ogg", "opus",
             "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp", "psd", "ai", "svg", "raw", "cr2", "nef", "arw", "dng": self = .media
        case "pdf", "doc", "docx", "pages", "numbers", "key", "keynote", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
             "md", "txt", "rtf", "epub", "tex": self = .documents
        case "swift", "rs", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "go", "c", "cc", "cpp", "cxx", "h", "hh", "hpp",
             "m", "mm", "java", "kt", "kts", "rb", "php", "sh", "zsh", "bash", "pl", "pm", "lua", "css", "scss", "sass",
             "less", "html", "htm", "vue", "svelte", "zig", "hs", "ml", "fs", "fsx", "cs", "vb", "scala", "clj", "ex", "exs": self = .code
        case "json", "jsonl", "ndjson", "csv", "tsv", "xml", "yaml", "yml", "toml", "ini", "cfg", "db", "sqlite", "sqlite3",
             "sql", "log", "plist", "parquet", "arrow", "bin", "dat", "pt", "pth", "onnx", "safetensors", "gguf", "ckpt": self = .data
        case "so", "dylib", "a", "o", "obj", "exe", "dll", "class", "wasm", "node", "pyc", "pyo", "d": self = .binaries
        default: self = .other
        }
    }

    var color: Color {
        switch self {
        case .archives: Tints.cyan
        case .diskImages: Tints.electricBlue
        case .installers: Tints.mint
        case .media: Tints.coral
        case .documents: Color(red: 0.69, green: 0.79, blue: 0.35)
        case .code: Tints.electricBlue
        case .data: Tints.yellow
        case .binaries: Tints.secondaryText
        case .other: Color(white: 0.45)
        }
    }
}

struct FileTypeStat: Identifiable, Sendable {
    var id: String { name }
    /// Display label: ".dmg" or "No extension".
    let name: String
    let ext: String
    let kind: FileKind
    private(set) var count = 0
    private(set) var bytes: Int64 = 0
    /// The largest matching file, so a row can jump straight to evidence.
    private(set) var largestID: Int?
    private var largestBytes: Int64 = 0

    init(name: String, ext: String, kind: FileKind) {
        self.name = name
        self.ext = ext
        self.kind = kind
    }

    mutating func add(_ node: DiskNode, bytes: Int64) {
        count += 1
        let (sum, overflow) = self.bytes.addingReportingOverflow(bytes)
        self.bytes = overflow ? Int64.max : sum
        if largestID == nil || bytes > largestBytes {
            largestID = node.id
            largestBytes = bytes
        }
    }
}

/// Aggregates files by extension over a subtree. Directories never count —
/// package-style folders (.app, .framework) keep their bytes spread across
/// the real files inside, matching Top Sizes and Age Map semantics.
struct FileTypeStats: Sendable {
    private var byExtension: [String: FileTypeStat] = [:]
    private(set) var totalBytes: Int64 = 0
    private(set) var totalFiles = 0
    private(set) var overflowBytes: Int64 = 0
    private(set) var overflowFiles = 0

    mutating func insert(_ node: DiskNode, bytes: Int64) {
        let ext = (node.name as NSString).pathExtension.lowercased()
        let (total, overflowed) = totalBytes.addingReportingOverflow(bytes)
        totalBytes = overflowed ? Int64.max : total
        totalFiles += 1
        var stat = byExtension[ext] ?? FileTypeStat(name: ext.isEmpty ? "No extension" : ".\(ext)", ext: ext, kind: FileKind(ext: ext))
        stat.add(node, bytes: bytes)
        byExtension[ext] = stat
    }

    /// Rows are ranked by bytes; everything past `limit` folds into the
    /// overflow counters so the footer can state what was hidden.
    mutating func sort(limit: Int) -> [FileTypeStat] {
        let all = byExtension.values.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name < $1.name
        }
        overflowBytes = 0; overflowFiles = 0
        for stat in all.dropFirst(limit) {
            let (sum, of) = overflowBytes.addingReportingOverflow(stat.bytes)
            overflowBytes = of ? Int64.max : sum
            overflowFiles += stat.count
        }
        return Array(all.prefix(limit))
    }
}

@MainActor final class ExplorerModel: ObservableObject {
    @Published private(set) var excludedFolders: [String] = UserDefaults.standard.stringArray(forKey: "excludedFolders") ?? [] {
        didSet {
            UserDefaults.standard.set(excludedFolders, forKey: "excludedFolders")
            // Existing results remain historical; clear prior cleanup approvals.
            staged.removeAll()
            incompleteCleanup.removeAll()
            exclusionResultsStale = scan != nil
            progress = "Exclusions updated · Cleanup queue cleared · Nothing moved"
        }
    }

    @Published private(set) var exclusionResultsStale = false

    func addExcludedFolders(_ urls: [URL]) {
        guard !busy else { return }
        let paths = FolderExclusions(paths: excludedFolders + urls.map { $0.standardizedFileURL.path }).paths
        if paths != excludedFolders { excludedFolders = paths }
    }

    func removeExcludedFolder(_ path: String) {
        guard !busy else { return }
        excludedFolders.removeAll { $0 == path }
    }

    @Published var cleanupRefreshPaths: [String] = UserDefaults.standard.stringArray(forKey: "cleanupRefreshPaths") ?? [] {
        didSet { UserDefaults.standard.set(cleanupRefreshPaths, forKey: "cleanupRefreshPaths") }
    }
    func rescanAfterCleanup() {
        guard !busy, staged.isEmpty, let path = cleanupRefreshPaths.first else { return }
        guard FileManager.default.isReadableFile(atPath: path) else {
            message = "The previous scan location is unavailable. Reconnect the disk or use Scan Folder to grant access again."
            return
        }
        start(URL(fileURLWithPath: path), allowProtectedFolder: lastScanAllowedProtectedFolder && scan?.rootPath == path)
    }
    @Published var showAbout = false
    @Published var showWelcome = false
    @Published var lastTrashedURLs: [URL] = []
    @Published var scan: ScanResult? { didSet { invalidateDuplicateReview(); duplicateSurvivorSelections = [:]; invalidateProjectReview(); invalidateAppDataReview() } }
    @Published var scanStorageAccounting: ScanStorageAccounting?
    @Published private(set) var promptAvoidanceFolders: [String] = []
    private var lastScanAllowedProtectedFolder = false
    let installedApplications = InstalledApplicationsModel()
    let dashboard = DashboardModel()
    lazy var conversationArchive = ConversationArchiveModel { [weak self] in
        self?.requestAISessionsRefresh()
    }
    @Published private(set) var aiSessionsRefreshID = UUID()
    @Published var aiSessionsSection: AISessionsSection = .sessions
    @Published var workspace: Workspace = .explore
    @Published var storageSection: StorageSection = .explore
    @Published var mode: MapMode = .treemap { didSet { refreshFocus() } }
    @Published var focus = 0 { didSet { refreshFocus() } }
    @Published var selected: Int?
    @Published var search = "" { didSet { refreshFocus() } }
    @Published var allocated = true { didSet { refreshFocus() } }
    @Published var mapMeasure: MapMeasure = .bytes
    @Published var mapIndex: StorageMapIndex?
    @Published var volumeFree: Int64?
    @Published var volumeCapacity: Int64?
    @Published var liveProgress: ScanProgress?
    @Published var busy = false
    @Published var progress = "Choose what to scan to begin"
    @Published var folderExplanation: FolderExplanationState?
    @Published var message: String?
    @Published var staged: Set<Int> = []
    @Published private(set) var incompleteCleanup: [Int: CleanupIncompleteReview] = [:]
    @Published var showCleanup = false
    // No background monitoring in the current product flow.
    let monitoring = false
    @Published var savedSnapshots: [SavedScanSnapshot] = []
    @Published var snapshotHistoryLoading = false
    @Published var snapshotHistoryWarning: String?
    @Published var snapshotNotice: String?
    @Published var lastSavedSnapshotStarted: Date?
    private var snapshotHistoryGeneration = UUID()
    private var snapshotDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorageDaddy/Scan History", isDirectory: true)
    }
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicatesLoading = false
    @Published var duplicatesError: String?
    @Published var duplicatesSearched = false
    private var duplicateTask: Task<Void, Never>?
    private var duplicateVersion = UUID()
    private var reviewBatchTask: Task<Void, Never>?
    private var duplicateSurvivorSelections: [Int: DuplicateSurvivorSelection] = [:]
    @Published var projectReviewRecords: [ProjectPurgeRecord] = []
    @Published var projectReviewStatus: ProjectPurgeViewStatus = .idle("Review project evidence after scanning a workspace.")
    private var projectReviewTask: Task<Void, Never>?
    private var projectReviewVersion = UUID()
    private var projectRecoveryPlans: [Int: String] = [:]
    private var stagedProjectOwners: [Int: Int] = [:]
    @Published var appDataReview: AppLeftoverReviewResult?
    @Published var appDataReviewLoading = false
    @Published var appDataReviewError: String?
    private var appDataReviewTask: Task<Void, Never>?
    private var appDataReviewVersion = UUID()
    private var appDataLibraryRoot: URL?
    private var stagedAppData: [Int: String] = [:]
    @Published var visible: [DiskNode] = []
    @Published var ranked: [DiskNode] = []
    @Published var ageHistogram: FileAgeHistogram?
    @Published var ageGranularity: FileAgeGranularity = .monthly { didSet { refreshFocus() } }
    @Published var ageRefreshing = false
    @Published var ageHistogramError: String?
    private var ageTask: Task<Void, Never>?
    @Published var fileTypeRows: [FileTypeStat] = []
    @Published var fileTypeSummary: FileTypeStats?
    @Published var quickWinNodes: [DiskNode] = []
    @Published var appNodes: [DiskNode] = []
    @Published var fileCount = 0
    @Published var snapshotBusy = false
    @Published var projectGrowth: [Int: Int64] = [:]
    @Published var reportFindingsByID: [Int: DeveloperFinding] = [:]
    @Published var reportProjectNames: [Int: String] = [:]
    @Published var developerReport: DeveloperReport?
    @Published var developerGroups: [DeveloperGroup] = []
    @Published private(set) var projectDependencies: ProjectDependencyDiscovery?
    @Published private(set) var projectDependenciesBusy = false
    @Published var previousDeveloperGroups: [DeveloperGroup]?
    @Published var previousDeveloperDate: Date?
    @Published var analysisElapsed: Double = 0
    @Published var insightsElapsed: Double = 0
    @Published var scanPeakRSS: UInt64?
    private var priorScanPeakRSS: UInt64?
    private var memoryTask: Task<Void, Never>?
    private var scanVersion = UUID()
    private var activeScanVersion: UUID?
    private var focusTask: Task<Void, Never>?
    private var focusVersion = UUID()
    private var task: Task<Void, Never>?
    private var projectDependenciesTask: Task<Void, Never>?
    private var scopedURL: URL?
    var node: DiskNode? { guard let scan, let id = selected, scan.nodes.indices.contains(id) else { return nil }; return scan.nodes[id] }
    func bytes(_ node: DiskNode) -> Int64 { allocated ? node.allocatedBytes : node.logicalBytes }
    func fileEntries(_ node: DiskNode) -> Int64 {
        guard let mapIndex, mapIndex.fileCounts.indices.contains(node.id) else { return node.isDirectory ? 0 : 1 }
        return mapIndex.fileCounts[node.id]
    }
    func mapWeight(_ node: DiskNode) -> Int64 { mapMeasure == .bytes ? bytes(node) : fileEntries(node) }
    func mapLabel(_ value: Int64) -> String { mapMeasure == .bytes ? DiskFormat.bytes(value) : "\(value.formatted()) \(value == 1 ? "file entry" : "file entries")" }
    func storageKind(_ node: DiskNode) -> StorageKind {
        guard let mapIndex, mapIndex.kinds.indices.contains(node.id) else { return .generic }
        return mapIndex.kinds[node.id]
    }
    var mapItems: [DiskNode] {
        guard let scan, scan.nodes.indices.contains(focus) else { return [] }
        return scan.nodes[focus].children.map { scan.nodes[$0] }.sorted { mapWeight($0) > mapWeight($1) }
    }
    func matchesFilter(_ node: DiskNode) -> Bool { search.isEmpty || node.name.localizedCaseInsensitiveContains(search) }
    func hasAncestor(_ id: Int, in ids: Set<Int>) -> Bool {
        guard let scan else { return false }
        var cursor: Int? = id
        while let current = cursor, scan.nodes.indices.contains(current) {
            if ids.contains(current) { return true }
            guard let parent = scan.nodes[current].parent, parent < current else { break }
            cursor = parent
        }
        return false
    }
    func toggleStage(_ id: Int) {
        if staged.contains(id) { unstage(id) } else { stage(id) }
    }
    var projectedFreeUpperBound: Int64? {
        guard let scan, let volumeFree else { return nil }
        let stagedBytes = staged.filter { scan.nodes.indices.contains($0) }.reduce(Int64.zero) { sum, id in
            let (value, overflow) = sum.addingReportingOverflow(max(0, scan.nodes[id].allocatedBytes))
            return overflow ? Int64.max : value
        }
        let (sum, overflow) = volumeFree.addingReportingOverflow(stagedBytes)
        return min(volumeCapacity ?? Int64.max, overflow ? Int64.max : sum)
    }
    func refreshFocus() {
        focusTask?.cancel(); ageTask?.cancel()
        ageHistogram = nil; ageHistogramError = nil; ageRefreshing = false
        guard let scan, scan.nodes.indices.contains(focus) else { visible = []; fileTypeRows = []; fileTypeSummary = nil; return }
        let version = UUID(); focusVersion = version
        let focus = focus, search = search, allocated = allocated, mode = mode
        if mode == .age {
            let granularity = ageGranularity, now = Date(), calendar = Calendar.current
            ageRefreshing = true
            ageTask = Task {
                let worker = Task.detached(priority: .userInitiated) {
                    try FileAgeHistogram.calculate(in: scan, focus: focus, granularity: granularity,
                        allocated: allocated, search: search, now: now, calendar: calendar)
                }
                do {
                    let histogram = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, focusVersion == version else { return }
                    ageHistogram = histogram; ageRefreshing = false
                } catch {
                    guard !Task.isCancelled, focusVersion == version else { return }
                    ageHistogramError = "Modification dates unavailable. Try refreshing this view."
                    ageRefreshing = false
                }
            }
        }
        focusTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                func size(_ n: DiskNode) -> Int64 { allocated ? n.allocatedBytes : n.logicalBytes }
                let visible = scan.nodes[focus].children.map { scan.nodes[$0] }.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { size($0) > size($1) }
                var files = NodeRanking(limit: 250, allocated: allocated)
                var types = FileTypeStats()
                guard mode == .top || mode == .types else { return (visible, files.sorted, types, [FileTypeStat]()) }
                var stack = [focus]
                while let id = stack.popLast() {
                    if Task.isCancelled { break }
                    let n = scan.nodes[id]
                    if n.isDirectory { stack.append(contentsOf: n.children) }
                    else if search.isEmpty || n.name.localizedCaseInsensitiveContains(search) {
                        if mode == .top { files.insert(n); continue }
                        types.insert(n, bytes: size(n))
                    }
                }
                let rows = types.sort(limit: 48)
                return (visible, files.sorted, types, rows)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, focusVersion == version else { return }
            visible = result.0; ranked = result.1
            fileTypeSummary = result.2; fileTypeRows = result.3
        }
    }
    func invalidateDuplicateReview() {
        duplicateTask?.cancel(); duplicateVersion = UUID()
        duplicateGroups = []; duplicatesLoading = false; duplicatesError = nil; duplicatesSearched = false
    }
    func invalidateProjectReview() {
        projectReviewTask?.cancel(); projectReviewVersion = UUID()
        projectReviewRecords = []; projectRecoveryPlans = [:]; stagedProjectOwners = [:]
        projectReviewStatus = .idle("Review project evidence after scanning a workspace.")
    }
    func reviewProjects() {
        guard let scan, let report = developerReport, !busy else { return }
        projectReviewTask?.cancel()
        let version = UUID(); projectReviewVersion = version
        let plans = projectRecoveryPlans
        projectReviewStatus = .loading
        projectReviewTask = Task {
            let worker = Task.detached(priority: .utility) {
                let preliminary = try ProjectPurgeReview.build(scan: scan, report: report, cancellationCheck: { try Task.checkCancellation() })
                var probes: [Int: ProjectPurgeProbe] = [:]
                for record in preliminary {
                    try Task.checkCancellation()
                    let git = try ProjectGitTrackingProbe.collect(scan: scan, projectID: record.id, artifactIDs: record.artifacts.map(\.id))
                    probes[record.id] = ProjectPurgeProbe(git: git, recoveryPlans: plans)
                }
                try Task.checkCancellation()
                return try ProjectPurgeReview.build(scan: scan, report: report, probes: probes, cancellationCheck: { try Task.checkCancellation() })
            }
            do {
                let records = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, projectReviewVersion == version else { return }
                projectReviewRecords = records; projectReviewStatus = .ready
                let allowed = Set(records.flatMap { $0.stageableArtifactIDs })
                for id in Array(stagedProjectOwners.keys) where !allowed.contains(id) { unstage(id) }
            } catch {
                guard !Task.isCancelled, projectReviewVersion == version else { return }
                projectReviewStatus = .error("Project evidence unavailable. Refresh the review to try again.")
            }
        }
    }
    func recordProjectRecoveryPlan(_ id: Int, plan: String?) {
        guard !busy, projectReviewStatus == .ready,
              projectReviewRecords.contains(where: { $0.artifacts.contains(where: { $0.id == id }) }) else { return }
        let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        projectRecoveryPlans[id] = trimmed?.isEmpty == false ? trimmed : nil
        unstage(id)
        reviewProjects()
    }
    func cancelProjectReview() {
        projectReviewTask?.cancel(); projectReviewVersion = UUID()
        projectReviewStatus = .idle("Review canceled. Refresh project evidence to continue.")
    }
    func stageProjectArtifacts(_ ids: [Int]) {
        guard !busy, projectReviewStatus == .ready,
              !ids.isEmpty, Set(ProjectPurgeReview.stageableSelection(Set(ids), in: projectReviewRecords)) == Set(ids) else { return }
        for record in projectReviewRecords {
            for id in ids where record.stageableArtifactIDs.contains(id) { stagedProjectOwners[id] = record.id }
        }
        stageReviewBatch(ids)
    }
    func invalidateAppDataReview() {
        appDataReviewTask?.cancel(); appDataReviewVersion = UUID()
        appDataReview = nil; appDataReviewLoading = false; appDataReviewError = nil
        appDataLibraryRoot = nil; stagedAppData = [:]
    }
    func refreshAppDataReview() {
        guard let scan, !busy else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        let roots = AppReferenceDiscovery.standardRoots(home: home)
        appDataReviewTask?.cancel()
        let version = UUID(); appDataReviewVersion = version
        appDataReviewLoading = true; appDataReviewError = nil; appDataReview = nil
        appDataReviewTask = Task {
            let worker = Task.detached(priority: .utility) {
                let reference = try AppReferenceDiscovery.collect(roots: roots)
                return try AppLeftoverReview.analyze(scan: scan, inventory: reference, libraryRoot: library,
                    cancellationCheck: { try Task.checkCancellation() })
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, appDataReviewVersion == version else { return }
                appDataReview = result; appDataLibraryRoot = library; appDataReviewLoading = false
                let candidates = Set(result.candidates.map(\.id))
                for id in Array(stagedAppData.keys) where !candidates.contains(id) { unstage(id) }
            } catch {
                guard !Task.isCancelled, appDataReviewVersion == version else { return }
                appDataReviewLoading = false; appDataReviewError = "App reference unavailable. Refresh to try again."
                for id in Array(stagedAppData.keys) { unstage(id) }
            }
        }
    }
    func inspectAppData(_ record: AppLeftoverRecord) {
        guard let scan, scan.nodes.indices.contains(record.id), scan.url(for: record.id).path == record.path,
              appDataReview?.records.contains(where: { $0.id == record.id && $0.path == record.path }) == true else { return }
        openStorage(.explore); open(scan.nodes[record.id])
    }
    func cancelAppDataReview() {
        appDataReviewTask?.cancel(); appDataReviewVersion = UUID()
        appDataReviewLoading = false
        appDataReviewError = "Review canceled. Refresh the app reference to continue."
    }
    func stageAppData(_ record: AppLeftoverRecord) {
        guard let scan, !busy, !appDataReviewLoading,
              appDataReview?.absenceEvidenceAvailable == true,
              appDataReview?.candidates.contains(where: { $0.id == record.id && $0.path == record.path }) == true,
              scan.nodes.indices.contains(record.id), scan.url(for: record.id).path == record.path else { return }
        stagedAppData[record.id] = record.path
        stage(record.id)
    }
    func findDuplicates() {
        guard let scan, !busy, !duplicatesLoading else { return }
        invalidateDuplicateReview()
        let version = duplicateVersion
        duplicatesLoading = true
        duplicateTask = Task {
            let worker = Task.detached(priority: .utility) { try await DuplicateFinder.find(in: scan) }
            do {
                let groups = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, duplicateVersion == version else { return }
                duplicateGroups = groups; duplicatesSearched = true; duplicatesLoading = false
            } catch {
                guard !Task.isCancelled, duplicateVersion == version else { return }
                duplicatesLoading = false
                duplicatesError = error.localizedDescription
            }
        }
    }
    /// The preflight is asynchronous; serial staging avoids dropping every item
    /// after the first one at the existing busy guard. Nothing moves to Trash here.
    func stageDuplicateCopies(_ ids: [Int]) {
        guard let scan, !busy, !duplicatesLoading, !ids.isEmpty else { return }
        let removals = Set(ids)
        let groups = duplicateGroups.filter { !removals.isDisjoint(with: $0.nodeIDs) }
        guard removals.isSubset(of: Set(groups.flatMap(\.nodeIDs))) else { return }
        var proposals: [Int: DuplicateSurvivorSelection] = [:]
        for group in groups {
            let members = Set(group.nodeIDs), kept = members.subtracting(removals)
            guard let key = members.min(), !kept.isEmpty else { return }
            // Direct previously staged copies are reconciled by this new Keep
            // choice. Ancestor folders require explicit removal in Cleanup.
            let externalStaged = staged.subtracting(members)
            let selection = DuplicateSurvivorSelection(members: members, kept: kept)
            do { try DuplicateSurvivorProtection.validateCoverage(scan: scan, selections: [selection], staged: externalStaged) }
            catch { message = error.localizedDescription; return }
            proposals[key] = selection
        }
        for group in groups { for id in group.nodeIDs { unstage(id) } }
        duplicateSurvivorSelections.merge(proposals) { _, latest in latest }
        stageReviewBatch(ids)
    }
    func stageReviewBatch(_ ids: [Int]) {
        guard !busy, let scan, ids.allSatisfy({ scan.nodes.indices.contains($0) && scan.nodes[$0].parent != nil }) else { return }
        reviewBatchTask?.cancel()
        let version = scanVersion
        reviewBatchTask = Task {
            for id in ids {
                guard !Task.isCancelled, scanVersion == version, !busy else { return }
                if hasAncestor(id, in: staged) { continue }
                stage(id)
                await task?.value
                guard hasAncestor(id, in: staged) else { return }
            }
        }
    }
    func scanUserCaches() {
        start(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches"), destination: .explore)
    }
    func scanHomeFolder() {
        start(FileManager.default.homeDirectoryForCurrentUser, destination: .explore)
    }
    func openStorage(_ section: StorageSection) {
        storageSection = section
        showWelcome = false
        workspace = .explore
    }
    func requestAISessionsRefresh() { aiSessionsRefreshID = UUID() }
    func chooseFolder() { chooseFolder(destination: nil) }
    private func chooseFolder(destination: Workspace?) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Scan Folder"
        if p.runModal() == .OK, let url = p.url {
            let protected = AutomaticScanPrivacy.promptAvoidancePaths(accessStatus: FullDiskAccessProbe.status())
            let chosen = url.standardizedFileURL.path
            let selectedProtectedFolder = protected.contains { chosen == $0 || chosen.hasPrefix($0 + "/") }
            start(url, destination: destination, allowProtectedFolder: selectedProtectedFolder)
        }
    }
    func rescan() { if let scan { start(URL(fileURLWithPath: scan.rootPath), allowProtectedFolder: lastScanAllowedProtectedFolder) } }
    func start(_ url: URL, destination: Workspace? = nil, allowProtectedFolder: Bool = false) {
        guard !busy else { return }
        lastScanAllowedProtectedFolder = allowProtectedFolder
        let protectedFolders = allowProtectedFolder ? [] : AutomaticScanPrivacy.promptAvoidancePaths(accessStatus: FullDiskAccessProbe.status())
        promptAvoidanceFolders = protectedFolders
        projectDependenciesTask?.cancel()
        projectDependenciesTask = nil
        projectDependencies = nil
        projectDependenciesBusy = false
        showWelcome = false
        lastTrashedURLs = []
        task?.cancel(); scanVersion = UUID(); staged = []; incompleteCleanup = [:]; busy = true; message = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = url; _ = url.startAccessingSecurityScopedResource()
        liveProgress = nil
        progress = "Scanning \(StorageLabels.location(url.path))…"
        let priorRSS = scanPeakRSS
        priorScanPeakRSS = priorRSS
        memoryTask?.cancel(); scanPeakRSS = ProcessMemory.residentBytes()
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                self?.sampleMemory()
            }
        }
        let version = scanVersion
        activeScanVersion = version
        task = Task { [self] in
            let clock = ContinuousClock(); let analysisStart = clock.now
            var didPublish = false
            defer {
                if scanVersion == version {
                    sampleMemory(); memoryTask?.cancel(); memoryTask = nil
                    if !didPublish { scanPeakRSS = priorRSS }
                    activeScanVersion = nil
                }
            }
            do {
                let result = try await DiskScanner.scan(root: url, excludedFolders: excludedFolders,
                    promptAvoidanceFolders: protectedFolders, progress: { [weak self] p in
                    Task { @MainActor [weak self] in guard let self, self.scanVersion == version, self.busy else { return }; self.liveProgress = p; self.progress = "\(p.entries.formatted()) entries · \(StorageLabels.location(p.path))" }
                })
                try Task.checkCancellation()
                guard !result.nodes.isEmpty else { throw NSError(domain: "Scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "This folder is excluded by settings or scan privacy rules. To include a protected folder, choose it with Scan Folder."]) }
                let summaryStart = clock.now
                let priorScan = self.scan?.rootPath == result.rootPath ? self.scan : nil
                let priorReport = priorScan == nil ? nil : developerReport
                let worker = Task.detached(priority: .utility) {
                    var quick = NodeRanking(limit: 6, allocated: true)
                    var apps: [DiskNode] = []; var fileCount = 0
                    for node in result.nodes {
                        if node.id & 255 == 0 { try Task.checkCancellation() }
                        if !node.isDirectory { fileCount += 1; continue }
                        if ["Downloads", "node_modules", "DerivedData", "Caches", "build", "Logs"].contains(node.name) { quick.insert(node) }
                        if node.name.hasSuffix(".app") { apps.append(node) }
                    }
                    apps.sort { $0.allocatedBytes > $1.allocatedBytes }
                    let groups = try DeveloperInsights.analyze(result, cancellationCheck: { try Task.checkCancellation() })
                    let report = try DeveloperReport.build(scan: result, groups: groups, cancellationCheck: { try Task.checkCancellation() })
                    var growth: [Int: Int64] = [:]
                    if let priorScan, let priorReport {
                        let before = Dictionary(uniqueKeysWithValues: priorReport.projects.map { (priorScan.url(for: $0.id).path, $0.allocatedBytes) })
                        for project in report.projects {
                            try Task.checkCancellation()
                            if let previous = before[result.url(for: project.id).path] { growth[project.id] = project.allocatedBytes - previous }
                        }
                    }
                    let findingIndex = Dictionary(uniqueKeysWithValues: report.findings.map { ($0.id, $0) })
                    let projectNames = Dictionary(uniqueKeysWithValues: report.projects.map { ($0.id, $0.name) })
                    var accounting: ScanStorageAccounting?
                    if ["/", "/System/Volumes/Data"].contains(result.rootPath) {
                        let volumes = SystemInventory.mountedVolumes()
                        let apfs = volumes.first(where: \.isStartupData).flatMap { StartupAPFSAccounting.collect(startup: $0) }
                        accounting = ScanStorageAccounting(scan: result, capacity: StartupCapacity(volumes: volumes), apfs: apfs)
                    }
                    let mapIndex = try StorageMapIndex(scan: result, groups: groups, cancellationCheck: { try Task.checkCancellation() })
                    let volume = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                    return (quick.sorted, apps, fileCount, groups, report, growth, findingIndex, projectNames, mapIndex, volume?.volumeAvailableCapacity.map(Int64.init), volume?.volumeTotalCapacity.map(Int64.init), accounting)
                }
                let summary = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }

                try Task.checkCancellation()
                if self.scan?.rootPath == result.rootPath {
                    previousDeveloperGroups = developerGroups; previousDeveloperDate = self.scan?.started
                } else { previousDeveloperGroups = nil; previousDeveloperDate = nil }
                developerGroups = summary.3
                developerReport = summary.4
                projectGrowth = summary.5
                reportFindingsByID = summary.6; reportProjectNames = summary.7
                mapIndex = summary.8
                volumeFree = summary.9; volumeCapacity = summary.10
                let summaryTime = summaryStart.duration(to: clock.now).components
                insightsElapsed = Double(summaryTime.seconds) + Double(summaryTime.attoseconds) / 1e18
                let readyTime = analysisStart.duration(to: clock.now).components
                analysisElapsed = Double(readyTime.seconds) + Double(readyTime.attoseconds) / 1e18
                didPublish = true
                if result.nodes.count > 1 || result.skipped == 0 { cleanupRefreshPaths.removeAll { $0 == result.rootPath } }
                self.scan = result; exclusionResultsStale = false; quickWinNodes = summary.0; appNodes = summary.1; fileCount = summary.2; focus = 0; selected = nil
                scanStorageAccounting = summary.11
                // A manual scan must land on results, even when launched from credits or another utility page.
                if let destination {
                    if destination == .explore { openStorage(.explore) }
                    else { workspace = destination }
                } else { openStorage(.explore) }
                snapshotNotice = nil
                progress = "\(fileCount.formatted()) files · \(SpeedFormat.duration(result.elapsed)) scan · \(result.skipped) skipped"
                if url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").standardizedFileURL.path {
                    // A cache-only scan must not start a separate walk of Home while
                    // macOS-protected folders are inaccessible. Even a readable-looking
                    // directory may block in opendir and leave the quick scan spinning.
                    if protectedFolders.isEmpty { discoverProjectDependencies(promptAvoidanceFolders: []) }
                }
            } catch is CancellationError { if scanVersion == version { progress = scan == nil ? "Scan cancelled · Choose a disk or folder to try again" : "Scan cancelled · Showing previous results" } }
            catch { if scanVersion == version { message = error.localizedDescription; progress = scan == nil ? "Scan failed · Choose another disk or folder" : "Scan failed · Showing previous results" } }
            guard scanVersion == version else { return }
            liveProgress = nil; busy = false
        }
    }
    private func discoverProjectDependencies(promptAvoidanceFolders: [String]) {
        projectDependenciesBusy = true
        let version = scanVersion
        let exclusions = excludedFolders
        projectDependenciesTask = Task { [weak self] in
            do {
                let result = try await ProjectDependencyDiscovery.discover(
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    excludedFolders: exclusions,
                    promptAvoidanceFolders: promptAvoidanceFolders,
                    progress: { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard let self, self.scanVersion == version, self.projectDependenciesBusy,
                                  update.directoriesVisited > (self.projectDependencies?.directoriesVisited ?? 0) else { return }
                            self.projectDependencies = update
                        }
                    }
                )
                guard !Task.isCancelled, let self, self.scanVersion == version else { return }
                self.projectDependencies = result
                self.projectDependenciesBusy = false
            } catch {
                guard !Task.isCancelled, let self, self.scanVersion == version else { return }
                self.projectDependenciesBusy = false
            }
        }
    }
    private func sampleMemory() {
        if let rss = ProcessMemory.residentBytes() { scanPeakRSS = max(scanPeakRSS ?? 0, rss) }
    }
    func cancel() {
        task?.cancel()
        if activeScanVersion != nil {
            // A filesystem access request can wait inside macOS. Detach its UI
            // immediately; a cancelled scan can never publish later results.
            scanVersion = UUID(); activeScanVersion = nil
            memoryTask?.cancel(); memoryTask = nil
            scanPeakRSS = priorScanPeakRSS
            liveProgress = nil; busy = false
            progress = scan == nil ? "Scan cancelled · Choose a folder to grant access" : "Scan cancelled · Showing previous results"
        }
    }
    func open(_ n: DiskNode) { selected = n.id; if n.isDirectory { focus = n.id; search = "" } }
    func goUp() { guard let scan else { return }; focus = scan.nodes[focus].parent ?? 0; selected = nil }
    func reveal(_ id: Int) { if let scan { NSWorkspace.shared.activateFileViewerSelecting([scan.url(for: id)]) } }
    func copyPath(_ id: Int) { if let scan { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(scan.url(for: id).path, forType: .string) } }
    func copyFolderPrompt(_ id: Int) {
        guard let prompt = folderPrompt(for: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        progress = "Copied a folder-explanation prompt · Paste it into your AI assistant"
    }
    private func folderPrompt(for id: Int) -> String? {
        guard let scan, scan.nodes.indices.contains(id), scan.nodes[id].isDirectory else { return nil }
        let node = scan.nodes[id]
        return FolderExplainer.prompt(
            path: scan.url(for: id).path,
            allocatedBytes: node.allocatedBytes,
            logicalBytes: node.logicalBytes,
            children: node.children.count,
            modified: node.modified,
            assessment: FolderArchetypes.assess(scan, folderID: id, category: cleanupCategory(id)),
        )
    }
    /// Asks a locally installed agent CLI (Claude, then Codex) to explain the
    /// folder. The path, scan measurements and inferred folder context are sent; the agent runs
    /// read-only and can be cancelled. Falls back to the copy-paste prompt when
    /// no supported CLI is installed.
    func explainFolder(_ id: Int) {
        guard let scan, let prompt = folderPrompt(for: id) else { return }
        guard let (agent, executable) = FolderExplainer.detectAgents().first else {
            copyFolderPrompt(id)
            progress = "No local Claude or Codex install found · Prompt copied to paste into your AI assistant"
            return
        }
        do {
            let task = try FolderExplainer.start(agent: agent, executable: executable, prompt: prompt)
            folderExplanation = FolderExplanationState(folderPath: scan.url(for: id).path, agentLabel: agent.label, prompt: prompt, task: task)
            Task.detached {
                let result = Result(catching: { try task.wait() })
                await MainActor.run { [weak self] in
                    guard let self, self.folderExplanation?.task === task else { return }
                    self.folderExplanation?.result = result
                }
            }
        } catch {
            progress = "Could not start \(agent.label) · \(error.localizedDescription)"
        }
    }
    func dismissFolderExplanation() {
        folderExplanation?.task.cancel()
        folderExplanation = nil
    }
    func openConversationArchive(provider: ConversationArchiveModel.Provider = .all) {
        if !conversationArchive.busy { conversationArchive.provider = provider }
        aiSessionsSection = .archive
        showCleanup = false
        workspace = .aiSessions
    }
    func sessionProvider(for id: Int) -> ConversationArchiveModel.Provider? {
        for group in developerGroups where group.rootIDs.contains(id) {
            if group.category == .codexSessions { return .codex }
            if group.category == .claudeSessions { return .claude }
        }
        return nil
    }
    func stage(_ id: Int) {
        guard let scan, !busy, !monitoring, scan.nodes.indices.contains(id) else { return }
        if let provider = sessionProvider(for: id) {
            let alert = NSAlert()
            alert.messageText = "Keep the conversation before cleaning up?"
            alert.informativeText = "Archive older conversations to keep prompts and replies in a compact export. Tool output and other session data are omitted, so it cannot restore a resumable session. Exporting alone does not free space."
            alert.addButton(withTitle: "Archive Conversations…")
            alert.addButton(withTitle: "Review for Cleanup")
            alert.addButton(withTitle: "Cancel")
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn { openConversationArchive(provider: provider); return }
            guard choice == .alertSecondButtonReturn else { return }
        }
        let version = scanVersion
        busy = true
        progress = "Checking \(StorageLabels.name(scan.nodes[id]))…"
        task = Task {
            defer { busy = false }
            do {
                var acknowledgement: CleanupIncompleteReview?
                do {
                    try await CleanupPreflight.validate(ids: [id], in: scan, excludedFolders: excludedFolders)
                } catch let CleanupPreflightError.incompleteRescan(_, review) {
                    try Task.checkCancellation()
                    guard scanVersion == version else { return }
                    guard review.canAcknowledge else { throw CleanupPreflightError.incompleteRescan(path: scan.url(for: id).path, review: review) }
                    guard showIncompleteReview(review, name: StorageLabels.name(scan.nodes[id]), allowsOverride: true) else {
                        progress = "Nothing added · Keep exploring"
                        return
                    }
                    try await CleanupPreflight.validate(ids: [id], in: scan, acknowledgedIncomplete: [id: review], excludedFolders: excludedFolders)
                    acknowledgement = review
                }
                try Task.checkCancellation()
                guard scanVersion == version else { return }
                let path = scan.url(for: id).path
                for other in Array(staged) where other != id {
                    let otherPath = scan.url(for: other).path
                    if path.hasPrefix(otherPath + "/") {
                        throw NSError(domain: "Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "A parent folder is already in your cleanup list."])
                    }
                    if otherPath.hasPrefix(path + "/") { unstage(other) }
                }
                staged.insert(id)
                incompleteCleanup[id] = acknowledgement
                progress = "Added \(StorageLabels.name(scan.nodes[id])) to Cleanup · Nothing moved yet"
            } catch is CancellationError {
                progress = "Check cancelled · Nothing added"
            } catch {
                message = "Could not add \(StorageLabels.name(scan.nodes[id])) to cleanup. \(error.localizedDescription)"
                progress = "Item needs attention · Nothing added"
            }
        }
    }
    var suggestedCacheIDs: [Int] {
        guard let scan else { return [] }
        return (developerReport?.findings ?? []).filter {
            scan.nodes.indices.contains($0.id) && !staged.contains($0.id)
                && CleanupGuidance.isSuggestedCache(category: $0.category, path: scan.url(for: $0.id).path)
        }.map(\.id)
    }

    /// The "easy cleanup" set: bounded package caches plus stale builds and
    /// dependency trees that met the AutoCleaner staleness thresholds.
    /// Staging is the only side effect — Trash still requires the review
    /// list's own confirmation.
    var easyCleanupIDs: [Int] {
        Array(Set(suggestedCacheIDs + autoCleanerSuggestions.map(\.id)))
    }

    var easyCleanupBytes: Int64 {
        guard let scan else { return 0 }
        return easyCleanupIDs.reduce(0) { $0 + scan.nodes[$1].allocatedBytes }
    }

    func stageEasyCleanup() {
        guard let scan, !busy, !monitoring else { return }
        let ids = easyCleanupIDs
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Stage \(ids.count) regenerable items for review?"
        alert.informativeText = "Build outputs, dependency folders and package caches that tools can usually rebuild or download again. Stop active installs and builds first. This does not check whether a tool is using them. Incomplete or changed folders will be skipped. Nothing moves until you review the list and confirm Move to Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stage for Review")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let version = scanVersion
        busy = true
        task = Task {
            defer { busy = false }
            var added = 0
            var skipped: [String] = []
            for id in ids {
                do {
                    try Task.checkCancellation()
                    guard scanVersion == version else { return }
                    let path = scan.url(for: id).path
                    if staged.contains(where: { let parent = scan.url(for: $0).path; return path == parent || path.hasPrefix(parent + "/") }) { continue }
                    progress = "Checking \(StorageLabels.name(scan.nodes[id]))…"
                    try await CleanupPreflight.validate(ids: [id], in: scan, excludedFolders: excludedFolders)
                    try Task.checkCancellation()
                    guard scanVersion == version else { return }
                    for other in Array(staged) where scan.url(for: other).path.hasPrefix(path + "/") { unstage(other) }
                    staged.insert(id)
                    added += 1
                } catch is CancellationError {
                    progress = "Check cancelled · \(added) added for review · Nothing moved"
                    return
                } catch {
                    skipped.append(StorageLabels.name(scan.nodes[id]))
                }
            }
            progress = "\(added) staged for review · \(skipped.count) skipped · Nothing moved"
            if !skipped.isEmpty {
                message = "Staged \(added) items for review. Could not fully verify: \(skipped.joined(separator: ", ")). Inspect these individually in Explore. Nothing was moved."
            }
            if added > 0 { openStorage(.cleanup) }
        }
    }

    func cleanupCategory(_ id: Int) -> DeveloperCategory? {
        developerReport?.findings.first(where: { $0.id == id })?.category
    }

    /// Auto Cleaner suggestions: stale, usually-regenerable developer folders.
    /// Notify-only — staging still goes through preflight and the review list.
    var autoCleanerSuggestions: [AutoCleanerSuggestion] {
        guard let scan else { return [] }
        return AutoCleaner.suggestions(scan: scan, findings: developerReport?.findings ?? [])
            .filter { !staged.contains($0.id) }
    }

    func unstage(_ id: Int) {
        staged.remove(id)
        incompleteCleanup.removeValue(forKey: id)
        stagedProjectOwners.removeValue(forKey: id)
        stagedAppData.removeValue(forKey: id)
    }

    func reviewIncompleteCleanup(_ id: Int) {
        guard let review = incompleteCleanup[id], let scan, scan.nodes.indices.contains(id) else { return }
        _ = showIncompleteReview(review, name: StorageLabels.name(scan.nodes[id]), allowsOverride: false)
    }

    private func showIncompleteReview(_ review: CleanupIncompleteReview, name: String, allowsOverride: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) couldn’t be fully checked"
        alert.informativeText = "\(review.skipped) unreadable or excluded \(review.skipped == 1 ? "item was" : "items were") skipped. Adding this folder includes those contents, which may contain important data. The displayed size may be incomplete.\n\nNothing moves now. Moving to Trash requires a separate confirmation, and unverified contents will move with the folder."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.string = review.details.joined(separator: "\n\n")
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: allowsOverride ? "Cancel" : "Done")
        if allowsOverride { alert.addButton(withTitle: "Add Anyway") }
        return alert.runModal() == .alertSecondButtonReturn
    }

    func trashStaged() {
        guard let scan, !busy, !monitoring, !staged.isEmpty else { return }
        let ids = staged.sorted()
        let version = scanVersion
        let acknowledgements = incompleteCleanup.filter { staged.contains($0.key) }
        let duplicateSelections = duplicateSurvivorSelections.values.filter { selection in
            selection.members.contains { hasAncestor($0, in: staged) }
        }
        do { try DuplicateSurvivorProtection.validateCoverage(scan: scan, selections: duplicateSelections, staged: staged) }
        catch { message = error.localizedDescription; return }
        let projectOwners = stagedProjectOwners.filter { staged.contains($0.key) }
        let recoveryPlans = projectRecoveryPlans
        let appDataPaths = stagedAppData.filter { staged.contains($0.key) }
        let libraryRoot = appDataLibraryRoot
        let alert = NSAlert()
        alert.messageText = "Move \(ids.count) \(ids.count == 1 ? "item" : "items") to Trash?"
        alert.informativeText = "Entire folders and their contents are included. Developer categories are descriptions, not recommendations to delete. Active environments, models and container volumes may be needed by your tools. We will check for changes again after you confirm."
        if !acknowledgements.isEmpty {
            let names = acknowledgements.keys.sorted().map { StorageLabels.name(scan.nodes[$0]) }.joined(separator: ", ")
            alert.informativeText += "\n\nAdded with an incomplete-check override: \(names). Their unreadable or excluded contents WILL also move to Trash. Those contents have not been verified."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; progress = "Checking cleanup candidates…"
        task = Task {
            defer { busy = false }
            do {
                // Confirmation can remain open indefinitely. Rescan afterward,
                // using exactly the candidates that the user approved.
                try DuplicateSurvivorProtection.validateSurvivors(scan: scan, selections: duplicateSelections, staged: Set(ids))
                try await ProjectProposalValidation.validate(scan: scan, artifactOwners: projectOwners,
                    recoveryPlans: recoveryPlans, excludedFolders: excludedFolders)
                if !appDataPaths.isEmpty {
                    guard let libraryRoot else { throw NSError(domain: "AppDataReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "App reference changed. Refresh App Data."]) }
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let referenceCheck = Task.detached(priority: .utility) {
                        let reference = try AppReferenceDiscovery.collect(roots: AppReferenceDiscovery.standardRoots(home: home))
                        return try AppLeftoverReview.analyze(scan: scan, inventory: reference, libraryRoot: libraryRoot,
                            cancellationCheck: { try Task.checkCancellation() })
                    }
                    let fresh = try await withTaskCancellationHandler { try await referenceCheck.value } onCancel: { referenceCheck.cancel() }
                    guard fresh.absenceEvidenceAvailable, appDataPaths.allSatisfy({ id, path in
                        fresh.candidates.contains { $0.id == id && $0.path == path }
                    }) else { throw NSError(domain: "AppDataReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "App reference changed or is incomplete. Refresh App Data and review again."]) }
                }
                try await CleanupPreflight.validate(ids: ids, in: scan, acknowledgedIncomplete: acknowledgements, excludedFolders: excludedFolders)
                try Task.checkCancellation()
                guard scanVersion == version, staged == Set(ids) else {
                    throw NSError(domain: "Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selection changed. Review it again."])
                }
                var moved = 0
                lastTrashedURLs = []
                do {
                    for id in ids {
                        try Task.checkCancellation()
                        let url = scan.url(for: id)
                        if FolderExclusions(paths: excludedFolders).blocksCleanup(url) {
                            throw CleanupPreflightError.excludedFolder(url.path)
                        }
                        try CleanupSafety.validate(url: url, expected: scan.nodes[id], root: URL(fileURLWithPath: scan.rootPath))
                        var trashedURL: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                        if !cleanupRefreshPaths.contains(scan.rootPath) { cleanupRefreshPaths.append(scan.rootPath) }
                        if let trashedURL { lastTrashedURLs.append(trashedURL as URL) }
                        unstage(id); moved += 1
                    }
                } catch {
                    if moved > 0 { requestAISessionsRefresh() }
                    message = "Stopped after moving \(moved) items to Trash. \(error.localizedDescription)"
                    progress = "Cleanup stopped · Rescan to refresh totals"
                    return
                }
                requestAISessionsRefresh()
                showCleanup = false
                openStorage(.cleanup)
                progress = "Cleanup complete · Rescan to refresh totals"
            } catch {
                message = "Nothing moved: \(error.localizedDescription)"; progress = "Cleanup stopped"
            }
        }
    }
    var snapshotAlreadySaved: Bool {
        guard let scan else { return false }
        return lastSavedSnapshotStarted == scan.started
    }

    func saveSnapshot() {
        guard let scan, !busy, !snapshotBusy, !snapshotAlreadySaved else { return }
        let directory = snapshotDirectory
        snapshotBusy = true
        snapshotNotice = nil
        Task {
            defer { snapshotBusy = false }
            do {
                let saved = try await Task.detached(priority: .utility) {
                    try SnapshotHistoryStore.save(scan: scan, directory: directory)
                }.value
                lastSavedSnapshotStarted = saved.scan.started
                // Saving a completed scan never changes the selected workspace.
                snapshotNotice = "Snapshot saved to History"
                await refreshSnapshotHistory()
            } catch {
                snapshotNotice = "Couldn’t save this snapshot. Try again."
            }
        }
    }

    func refreshSnapshotHistory() async {
        let request = UUID()
        snapshotHistoryGeneration = request
        snapshotHistoryLoading = true
        let directory = snapshotDirectory
        defer { if snapshotHistoryGeneration == request { snapshotHistoryLoading = false } }
        do {
            let listing = try await Task.detached(priority: .utility) {
                try SnapshotHistoryStore.load(directory: directory)
            }.value
            guard snapshotHistoryGeneration == request else { return }
            savedSnapshots = listing.snapshots
            var warnings: [String] = []
            if listing.unreadableCount > 0 { warnings.append("\(listing.unreadableCount) saved snapshots couldn’t be read.") }
            if listing.limitReached { warnings.append("The saved-history display limit was reached.") }
            snapshotHistoryWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        } catch {
            guard snapshotHistoryGeneration == request else { return }
            snapshotHistoryWarning = "Couldn’t load saved history. Try refreshing. Your saved files remain on this Mac."
        }
    }
}

struct FolderExplanationState: Identifiable {
    let id = UUID()
    let folderPath: String
    let agentLabel: String
    let prompt: String
    let task: FolderExplainTask
    var result: Result<FolderExplanationResult, Error>?
}
