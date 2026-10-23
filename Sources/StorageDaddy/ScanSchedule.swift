import AppKit
import Darwin
import DiskCore
import SwiftUI

enum ScanScheduleInterval: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 5, fifteenMinutes = 15, hourly = 60
    var id: Int { rawValue }
    var title: String { self == .hourly ? "Every hour" : "Every \(rawValue) minutes" }
}

/// Pure scheduling policy. Due work remains due while blocked; it is never
/// allowed to clear a review, change folders, or run a catch-up burst.
enum ScanSchedulePolicy {
    enum Decision: Equatable, Sendable {
        case disabled, waiting, deferred(String), run
    }
    static func decision(enabled: Bool, hasApprovedFolder: Bool, dueAt: Date?, now: Date,
                         approvedPath: String?, currentScanRoot: String?, blockReason: String?) -> Decision {
        guard enabled else { return .disabled }
        guard hasApprovedFolder, let approvedPath else { return .deferred("Choose a folder before enabling recurring scans.") }
        guard let dueAt, now >= dueAt else { return .waiting }
        if let blockReason { return .deferred(blockReason) }
        if let currentScanRoot, currentScanRoot != approvedPath {
            return .deferred("The current scan folder changed. Use the current folder below, or scan the scheduled folder again.")
        }
        return .run
    }
    static func nextRun(after completion: Date, interval: ScanScheduleInterval) -> Date {
        completion.addingTimeInterval(Double(interval.rawValue) * 60)
    }
}

struct ScanScheduleFolder: Codable, Equatable, Sendable {
    let path: String
    let bookmark: Data
    let device: UInt64
    let inode: UInt64
    let allowProtectedFolder: Bool
}

private struct ScanScheduleRecord: Codable {
    var enabled = false
    var interval: ScanScheduleInterval = .hourly
    var folder: ScanScheduleFolder?
    var nextRun: Date?
    var lastRun: Date?
    var lastResult: String?
    var pendingStartedAt: Date?
    var requireIdle: Bool?
    var idleMinutes: Int?
}

/// ExplorerModel implements these tiny wrappers in App.swift, where its private
/// original protected-folder consent and scoped URL remain accessible:
///
///   var scanScheduleCandidate: (url: URL, allowProtectedFolder: Bool)?
///   var scanScheduleBlockReason: String?
///   func beginScheduledScan(_ url: URL, allowProtectedFolder: Bool) -> Bool
///
/// The scheduler holds no strong reference back to the explorer. Its single
/// timer lives with the running app and does not depend on window visibility.
@MainActor
final class ScanScheduleModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var interval: ScanScheduleInterval = .hourly
    @Published private(set) var requireIdle = false
    @Published private(set) var idleMinutes = 10
    @Published private(set) var approvedPath: String?
    @Published private(set) var nextRun: Date?
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastResult: String?
    @Published private(set) var status = "Recurring scans are off."
    private weak var explorer: ExplorerModel?
    private let defaults: UserDefaults
    private let key = "recurringFullScan.v1"
    private var record = ScanScheduleRecord()
    private var timer: Task<Void, Never>?
    private var inFlight: (root: String, previousScan: Date?, requestedAt: Date)?

    init(explorer: ExplorerModel, defaults: UserDefaults = .standard) {
        self.explorer = explorer; self.defaults = defaults
        if let data = defaults.data(forKey: key), data.count <= 65_536,
           let saved = try? JSONDecoder().decode(ScanScheduleRecord.self, from: data) {
            record = saved
        }
        if record.enabled && record.folder == nil { record.enabled = false }
        if record.pendingStartedAt != nil {
            record.pendingStartedAt = nil
            record.lastResult = "The previous scheduled scan was interrupted when the app closed."
            record.nextRun = record.enabled ? ScanSchedulePolicy.nextRun(after: Date(), interval: record.interval) : nil
            persist()
        } else if record.enabled {
            // Resume an approved schedule after a short grace period, without
            // replaying every interval missed while the app was closed.
            record.nextRun = max(record.nextRun ?? Date(), Date().addingTimeInterval(30))
        }
        publish()
        status = record.enabled ? "Recurring full scans resume while StorageDaddy is running." : "Recurring scans are off."
        start()
    }
    deinit { timer?.cancel() }

    func start() {
        guard timer == nil, record.enabled || inFlight != nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
    func setEnabled(_ value: Bool) {
        guard value != record.enabled else { return }
        guard !value || record.folder != nil else { status = "Use the current folder before enabling recurring scans."; return }
        record.enabled = value
        record.nextRun = value ? ScanSchedulePolicy.nextRun(after: Date(), interval: record.interval) : nil
        status = value ? "Recurring full scans are enabled for this folder." : "Recurring scans are off."
        persist(); publish()
        if value { start() }
        else if inFlight == nil { timer?.cancel(); timer = nil }
    }
    func setInterval(_ value: ScanScheduleInterval) {
        guard value != record.interval else { return }
        record.interval = value
        if record.enabled && inFlight == nil { record.nextRun = ScanSchedulePolicy.nextRun(after: Date(), interval: value) }
        persist(); publish()
    }
    func setRequireIdle(_ value: Bool) { record.requireIdle = value; persist(); publish() }
    func setIdleMinutes(_ value: Int) { record.idleMinutes = min(120, max(1, value)); persist(); publish() }
    func approveCurrentFolder() {
        guard let candidate = explorer?.scanScheduleCandidate else {
            status = "Scan a folder, then choose it here for recurring scans."; return
        }
        guard inFlight == nil else { status = "Wait for the scheduled scan to finish before changing its folder."; return }
        do {
            let canonical = candidate.url.standardizedFileURL.resolvingSymlinksInPath()
            let identity = try Self.identity(canonical)
            let bookmark: Data
            do {
                bookmark = try candidate.url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                // Unsandboxed builds can use a normal bookmark. Resolution still
                // validates the exact approved canonical path/device/inode.
                bookmark = try candidate.url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            guard bookmark.count <= 32_768 else { throw Self.failure("The folder bookmark is too large to save.") }
            record.folder = ScanScheduleFolder(path: canonical.path, bookmark: bookmark, device: identity.device,
                inode: identity.inode, allowProtectedFolder: candidate.allowProtectedFolder)
            if record.enabled { record.nextRun = ScanSchedulePolicy.nextRun(after: Date(), interval: record.interval) }
            status = "Folder approved for recurring scans. The original scan privacy choices and current exclusions apply."
            persist(); publish()
        } catch { status = "Could not approve this folder: \(error.localizedDescription)" }
    }
    func forgetFolder() {
        guard inFlight == nil else { status = "Wait for the scheduled scan to finish before forgetting its folder."; return }
        record.enabled = false; record.folder = nil; record.nextRun = nil
        timer?.cancel(); timer = nil
        status = "Scheduled folder forgotten. Recurring scans are off."
        persist(); publish()
    }

    func tick(now: Date = Date()) {
        guard record.enabled || inFlight != nil else { return }
        guard let explorer else { timer?.cancel(); timer = nil; return }
        if let flight = inFlight {
            guard !explorer.isScanning && !explorer.busy else { return }
            record.pendingStartedAt = nil
            record.lastRun = now
            if let scan = explorer.scan, scan.rootPath == flight.root,
               scan.started != flight.previousScan, scan.started >= flight.requestedAt.addingTimeInterval(-1) {
                record.lastResult = "Completed · \(scan.nodes.count.formatted()) entries · \(scan.skipped.formatted()) skipped"
            } else { record.lastResult = explorer.message ?? "The scheduled scan was cancelled or could not complete." }
            record.nextRun = record.enabled ? ScanSchedulePolicy.nextRun(after: now, interval: record.interval) : nil
            inFlight = nil
            status = record.enabled ? "Waiting for the next scheduled scan." : "Recurring scans are off."
            persist(); publish()
            if !record.enabled { timer?.cancel(); timer = nil }
            return
        }
        guard SystemIdlePolicy.allows(requireIdle: record.requireIdle ?? false, minutes: record.idleMinutes ?? 10,
                                      idleSeconds: SystemIdlePolicy.idleSeconds) else {
            status = "Waiting for the Mac to be idle."; return
        }
        let decision = ScanSchedulePolicy.decision(enabled: record.enabled, hasApprovedFolder: record.folder != nil,
            dueAt: record.nextRun, now: now, approvedPath: record.folder?.path,
            currentScanRoot: explorer.scan?.rootPath, blockReason: explorer.scanScheduleBlockReason)
        switch decision {
        case .disabled: break
        case .waiting: break
        case let .deferred(reason): status = "Waiting · " + reason
        case .run:
            guard let approved = record.folder else { return }
            do {
                var stale = false
                let scoped = try URL(resolvingBookmarkData: approved.bookmark,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw Self.failure("The folder approval is stale. Use the current folder again.") }
                let access = scoped.startAccessingSecurityScopedResource()
                defer { if access { scoped.stopAccessingSecurityScopedResource() } }
                let canonical = scoped.standardizedFileURL.resolvingSymlinksInPath()
                let identity = try Self.identity(canonical)
                guard canonical.path == approved.path, identity.device == approved.device, identity.inode == approved.inode else {
                    throw Self.failure("The scheduled folder moved or was replaced. Use the current folder again.")
                }
                let previous = explorer.scan?.started
                // beginScheduledScan rechecks the full busy/review gate in the
                // same actor turn, then starts with background:true. It must
                // retain its own scope, as normal ExplorerModel.start does.
                guard explorer.beginScheduledScan(scoped, allowProtectedFolder: approved.allowProtectedFolder) else {
                    status = "Waiting · A storage operation or review is in progress."; return
                }
                inFlight = (approved.path, previous, now)
                record.pendingStartedAt = now; record.nextRun = nil
                status = "Scheduled full scan in progress."
                persist(); publish()
            } catch {
                // Never fall back to an arbitrary path or silently broaden
                // access when a bookmark or directory identity fails.
                record.enabled = false; record.nextRun = nil
                record.lastResult = error.localizedDescription
                status = "Recurring scans paused. " + error.localizedDescription
                persist(); publish()
                timer?.cancel(); timer = nil
            }
        }
    }
    private static func identity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw failure("The approved folder is unavailable or is no longer a regular directory.")
        }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "ScanSchedule", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private func persist() {
        do { defaults.set(try JSONEncoder().encode(record), forKey: key) }
        catch { status = "The schedule could not be saved. Changes apply only while this app remains open." }
    }
    private func publish() {
        requireIdle = record.requireIdle ?? false; idleMinutes = min(120, max(1, record.idleMinutes ?? 10))
        enabled = record.enabled; interval = record.interval; approvedPath = record.folder?.path
        nextRun = record.nextRun; lastRun = record.lastRun; lastResult = record.lastResult
    }
}

/// Add as a Settings tab or inside the General tab's ScrollView.
struct ScanScheduleSettingsView: View {
    @ObservedObject var schedule: ScanScheduleModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Recurring Scans").font(.title2.weight(.semibold))
                Text("Keep history current with full scans of one approved folder while StorageDaddy is running. The window can stay closed.")
                    .foregroundStyle(Tints.secondaryText)
                if let path = schedule.approvedPath {
                    Label(path, systemImage: "folder").font(.callout).textSelection(.enabled).lineLimit(3)
                } else { Text("No folder approved yet").foregroundStyle(Tints.secondaryText) }
                HStack {
                    Button("Use Current Scan Folder", action: schedule.approveCurrentFolder)
                        .buttonStyle(StorageButtonStyle(prominent: true))
                    if schedule.approvedPath != nil { Button("Forget Folder", action: schedule.forgetFolder) }
                }
                Toggle("Enable recurring full scans", isOn: Binding(get: { schedule.enabled }, set: { schedule.setEnabled($0) }))
                    .disabled(schedule.approvedPath == nil)
                Picker("Scan frequency", selection: Binding(get: { schedule.interval }, set: { schedule.setInterval($0) })) {
                    ForEach(ScanScheduleInterval.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 320)
                Toggle("Only scan when this Mac is idle", isOn: Binding(get: { schedule.requireIdle }, set: { schedule.setRequireIdle($0) }))
                if schedule.requireIdle {
                    Stepper("Idle for \(schedule.idleMinutes) minutes", value: Binding(get: { schedule.idleMinutes }, set: { schedule.setIdleMinutes($0) }), in: 1...120)
                }
                if let date = schedule.nextRun { LabeledContent("Next scan", value: date.formatted(date: .abbreviated, time: .shortened)) }
                if let date = schedule.lastRun { LabeledContent("Last scheduled scan", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Text(schedule.status).font(.callout).foregroundStyle(Tints.mint).fixedSize(horizontal: false, vertical: true)
                if let result = schedule.lastResult { Text(result).font(.caption).foregroundStyle(Tints.secondaryText).textSelection(.enabled) }
                Text("Scans wait for cleanup selections, reviews, file moves, exports, history operations and agent requests. They keep your current page and use your current excluded folders. Changing the scan folder holds this schedule until you approve the new one.")
                    .font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(28)
        }.tint(Tints.mint).buttonStyle(StorageButtonStyle()).background(AppColors.canvas).foregroundStyle(AppColors.ink)
    }
}
