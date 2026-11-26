import Combine
import SwiftUI
import DiskCore

/// Keep one session for the lifetime of the host application. Navigation never replaces an active scan or its review model.
@MainActor
public final class StorageWorkspaceSession: ObservableObject {
    let model: ExplorerModel
    fileprivate let settingsUpdates = AppUpdates()
    @Published public private(set) var cleanupCandidates: [StorageWorkspaceCandidate] = []
    @Published public private(set) var cleanupProgress = ""
    @Published public private(set) var cleanupIsBusy = false
    /// Measured candidates available now. Additional candidates can arrive while cleanupIsBusy is true.
    @Published public private(set) var cleanupMeasuredBytes: Int64?
    @Published public private(set) var observedFreeSpaceChange: Int64?
    private var observers = Set<AnyCancellable>()
    private var started = false

    public convenience init() {
        let standalone = UserDefaults(suiteName: "local.fleet.storagedaddy") ?? .standard
        self.init(defaults: .standard, standalone: standalone)
    }

    init(defaults: UserDefaults, standalone: UserDefaults, agentDirectory: URL = AgentAccessModel.embeddedDirectory) {
        // Both apps use the same protected-folder list, including changes made after migration.
        for key in ["developerCleanupFolders", "developerCleanupFolder", "automaticallySaveScans",
                    "scanWorkerCount", "binaryStorageUnits", "colorBlindMap"] where defaults.object(forKey: key) == nil {
            if let previous = standalone.object(forKey: key) { defaults.set(previous, forKey: key) }
        }
        model = ExplorerModel(developerCleanupPreferences: defaults, exclusionPreferences: standalone, agentDirectory: agentDirectory)
        model.$progress.combineLatest(model.$culpritSearchHome)
            .map { $1 == nil ? "" : $0 }.removeDuplicates().assign(to: &$cleanupProgress)
        model.$busy.combineLatest(model.$culpritSearchHome)
            .map { $0 && $1 != nil }.removeDuplicates().assign(to: &$cleanupIsBusy)
        model.$developerCleanupPlan.combineLatest(model.$developerCleanupOutcome)
            .sink { [weak self] plan, outcome in
                let candidates = StorageWorkspaceCandidate.ranked(in: plan, outcome: outcome)
                self?.cleanupCandidates = candidates
                if let device = plan?.startupDevice, device != 0 {
                    self?.cleanupMeasuredBytes = candidates.reduce(0) { $0 + $1.allocatedBytes }
                } else {
                    self?.cleanupMeasuredBytes = nil
                }
            }
            .store(in: &observers)
        model.$spaceTargetResult.sink { [weak self] result in
            guard let before = self?.model.capacityBeforeCleanup, let result, result.total == before.total else {
                self?.observedFreeSpaceChange = nil
                return
            }
            self?.observedFreeSpaceChange = result.available - before.available
        }.store(in: &observers)
    }

    public func start() {
        guard !started else { return }
        started = true
        model.scanSchedule.start()
    }

    public var activeWorkDescription: String? { model.activeWorkDescription }

    public static func measureCapacity() async -> StorageWorkspaceCapacity? {
        await Task.detached(priority: .utility) {
            StartupCapacity.measure().map { StorageWorkspaceCapacity(totalBytes: $0.total, freeBytes: $0.available) }
        }.value
    }

    /// Start native candidate discovery. Deletion always remains in the native review and confirmation workflow.
    public func findSpaceToClean() {
        guard model.canStartDeveloperCleanup else { return }
        if model.isFindingStorageCulprits && model.developerCleanupPlan != nil && model.developerCleanupOutcome == nil { return }
        model.openSpaceTarget(model.dashboard.report.flatMap(StartupCapacity.init(report:)))
    }

    public func chooseFolder() { model.chooseFolder() }
    public func showWidget() { model.runtime.showWidget() }

    fileprivate var requestedWorkspace: Workspace?

    func activate(_ route: String) {
        model.refreshExcludedFolders()
        model.showWelcome = false
        switch route {
        case "cleanup", "find-space-to-clean":
            model.workspace = .cleanup
            if !model.isFindingStorageCulprits || model.developerCleanupPlan == nil { findSpaceToClean() }
        case "quick-cleanup": model.openQuickCleanup()
        case "worktrees", "git-worktrees", "developer", "developer-insights": model.workspace = .developer
        case "explore", "disk-explorer-file-search": model.openStorage(.explore)
        case "files", "find-files": model.workspace = .findFiles
        case "duplicates": model.workspace = .duplicates
        case "applications": model.workspace = .applications
        case "ai-sessions", "ai-sessions-archives": model.workspace = .aiSessions
        case "history", "scan-history-growth": model.workspace = .snapshots
        case "easy-move", "easy-move-recovery":
            model.workspace = .snapshots
            model.moves.showHistory()
        case "projects", "projects-app-data": model.workspace = .projects
        case "app-data": model.workspace = .appData
        case "mac-controls": model.workspace = .macControls
        case "drive-monitoring", "drive-monitoring-widget": model.workspace = .driveMonitoring
        case "processes": model.workspace = .processes
        case "agent-access", "agent-access-settings": model.workspace = .agents
        case "acknowledgments": model.workspace = .acknowledgments
        case "settings": break
        default: model.workspace = .dashboard
        }
        requestedWorkspace = model.workspace
    }
}

public struct StorageWorkspaceCandidate: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let allocatedBytes: Int64
    public let kind: String

    static func ranked(in plan: DeveloperCleanupReview?, outcome: DeveloperCleanupReview.Outcome?) -> [Self] {
        guard let plan, let device = plan.startupDevice, device != 0 else { return [] }
        let attempted = (outcome?.deleted ?? []).union(outcome?.trashed ?? []).union(outcome?.kept.keys.map { $0 } ?? [])
        return plan.items.compactMap { item -> Self? in
            guard item.device == device, item.keptReason == nil, item.canDeletePermanently,
                  item.allocatedBytes > 0, !attempted.contains(item.id) else { return nil }
            let scope = plan.scopes[item.id.scope]
            let kind: String
            if let generated = scope.generated { kind = generated.title }
            else if scope.worktree != nil { kind = "Inactive worktree" }
            else if let cache = scope.cache { kind = cache.displayName }
            else if URL(fileURLWithPath: item.path).lastPathComponent == "node_modules" { kind = "Installed dependencies" }
            else { kind = "Build artifact" }
            return Self(path: item.path, allocatedBytes: item.allocatedBytes, kind: kind)
        }.sorted { $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes }
    }
}

public struct StorageWorkspaceCapacity: Sendable {
    public let totalBytes: Int64
    public let freeBytes: Int64
}

@MainActor
public struct StorageWorkspaceView: View {
    private let session: StorageWorkspaceSession
    private let route: String
    private let onNavigate: (String) -> Void
    @ObservedObject private var model: ExplorerModel
    @Environment(\.scenePhase) private var scenePhase

    public init(session: StorageWorkspaceSession, route: String, onNavigate: @escaping (String) -> Void = { _ in }) {
        self.session = session
        self.route = route
        self.onNavigate = onNavigate
        _model = ObservedObject(wrappedValue: session.model)
    }

    public var body: some View {
        Group {
            if route == "settings" {
                StorageSettingsView(updates: session.settingsUpdates, embedded: true)
            } else {
                ExplorerView(runsLaunchActions: false, embedded: true,
                             worktreesOnly: route == "worktrees" || route == "git-worktrees")
            }
        }
        .environmentObject(session.model)
        .onChange(of: route, initial: true) { _, next in session.activate(next) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshExcludedFolders() } }
        .onChange(of: model.busy) { _, busy in
            if !busy && route == "cleanup" && model.workspace == .cleanup && !model.isFindingStorageCulprits {
                session.findSpaceToClean()
            }
        }
        .onChange(of: model.workspace) { _, workspace in
            guard route != "settings", session.requestedWorkspace != workspace else { return }
            let key: String = switch workspace {
            case .dashboard: "dashboard"
            case .cleanup: "cleanup"
            case .developer: "developer"
            case .explore: "explore"
            case .findFiles: "files"
            case .applications: "applications"
            case .duplicates: "duplicates"
            case .aiSessions: "ai-sessions"
            case .snapshots: "history"
            case .projects: "projects"
            case .appData: "app-data"
            case .macControls: "mac-controls"
            case .processes: "processes"
            case .driveMonitoring: "drive-monitoring"
            case .agents: "agent-access"
            case .acknowledgments: "acknowledgments"
            }
            onNavigate(key)
        }
    }
}
