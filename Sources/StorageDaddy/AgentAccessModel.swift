import Foundation
import AppKit
import SwiftUI
import DiskCore
import AgentBridge

struct AgentSession: Codable, Identifiable {
    var id = UUID()
    var name: String
    var tokenHash: String
    var role: AgentRole
    var requestedPermissions: Set<String>
    var approvedAt = Date()
    var revokedAt: Date?
    var lastAction: String?
    var lastActionAt: Date?
    var blocked = 0
    var oauthClientID: String? = nil
    var connection: String? = nil
    var permissions: Set<String> { revokedAt == nil ? role.permissions.intersection(requestedPermissions) : [] }
}

struct AgentPairing: Identifiable {
    var id = UUID()
    var client: String
    var tokenHash: String
    var createdAt = Date()
    var requestedPermissions: Set<String>
    var oauthClientID: String? = nil
    var connection = "Private same-account stdio connection"
}

struct AgentReviewRequest: Codable, Identifiable {
    var id = UUID()
    var sessionID: UUID
    var agent: String
    var reason: String
    var permanent: Bool
    var path: String
    var device: UInt64
    var inode: UInt64
    var scanStarted: Date
    var requestedAt = Date()
    var outcome = "Waiting for native review"
    var pending = true
}

struct AgentAuditEntry: Codable, Identifiable {
    var id = UUID()
    var at = Date()
    var session: String
    var action: String
    var blocked: Bool
}

private struct AgentPolicy: Codable {
    var sessions: [AgentSession] = []
    var reviews: [AgentReviewRequest] = []
    var audit: [AgentAuditEntry] = []
    var approvedRoots: [String] = []
    var oauthRegistrations: [AgentOAuth.Registration]?
}

@MainActor final class AgentAccessModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var listening = false
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var pairings: [AgentPairing] = []
    @Published private(set) var reviews: [AgentReviewRequest] = []
    @Published private(set) var audit: [AgentAuditEntry] = []
    @Published private(set) var approvedRoots: [String] = []
    @Published var error: String?
    @Published private(set) var extensionWorking = false
    @Published private(set) var extensionURL: URL?
    private weak var explorer: ExplorerModel?
    private let server = AgentSocketServer()
    private let httpServer = AgentHTTPServer()
    private var oauth: AgentOAuth?
    private var oauthRegistrations: [AgentOAuth.Registration] = []
    private let directory: URL
    private let httpPort: UInt16
    private var scanOwner: (sessionID: UUID, version: UUID)?
    private var pendingStaging: [Int: UUID] = [:]
    private var policyHealthy = true
    private var deniedHashes: Set<String> = []
    private var stagedRequests: [Int: UUID] = [:]
    var waitingReviewCount: Int { reviews.filter(\.pending).count }
    var waitingApprovalCount: Int { pairings.filter { Date().timeIntervalSince($0.createdAt) < 600 }.count }
    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storagedaddy-mcp").path }
    var socketPath: String { AgentSecurity.socketPath(for: directory) }
    var configuration: String {
        let escaped = helperPath.replacingOccurrences(of: "'", with: "'\\''")
        return "codex mcp add storagedaddy --url http://127.0.0.1:\(httpPort)/mcp --oauth-client-registration dcr\nclaude mcp add --scope user --transport stdio storagedaddy -- '\(escaped)'"
    }

    init(explorer: ExplorerModel, directory: URL = AgentSecurity.directory, httpPort: UInt16 = 51736) {
        self.explorer = explorer; self.directory = directory; self.httpPort = httpPort
        let file = directory.appendingPathComponent("agent-policy.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let policy = try AgentSecurity.load(AgentPolicy.self, from: file)
                guard policy.sessions.count <= 100, policy.reviews.count <= 700, policy.audit.count <= 200, policy.approvedRoots.count <= 32,
                      policy.sessions.allSatisfy({ AgentSecurity.validHash($0.tokenHash) }) else { throw AgentSecurity.failure("Agent policy exceeds its limits.") }
                sessions = policy.sessions; reviews = policy.reviews; audit = policy.audit; approvedRoots = policy.approvedRoots; oauthRegistrations = Array((policy.oauthRegistrations ?? []).prefix(100))
            } catch { self.error = "Saved agent access could not be read. Access remains off. \(error.localizedDescription)"; policyHealthy = false }
        }
        // Always starts off. Restoring the app never starts an implicit listener.
    }

    func setEnabled(_ value: Bool) {
        if !value { enabled = false; listening = false; server.stop(); httpServer.stop(); oauth = nil; pairings = []; return }
        guard policyHealthy else { return }
        do {
            try server.start(path: socketPath) { [weak self] request in
                guard let self else { return .object(["error": .string("StorageDaddy closed.")]) }
                return await self.handle(request)
            }
            let oauth = AgentOAuth(port: httpPort, registrations: oauthRegistrations, onPair: { [weak self] client, hash, permissions, redirect, clientID in
                guard let self, self.enabled, self.pairings.count < 20 else { return }
                self.pairings.append(AgentPairing(client: client, tokenHash: hash, requestedPermissions: permissions, oauthClientID: clientID, connection: "HTTP OAuth · Redirect: " + redirect))
            }, status: { [weak self] hash in
                guard let self, self.enabled else { return "revoked" }
                if self.deniedHashes.contains(hash) { return "denied" }
                if let session = self.sessions.first(where: { $0.tokenHash == hash }) { return session.revokedAt == nil ? "approved" : "revoked" }
                return "pending"
            }, permissions: { [weak self] hash in
                self?.sessions.first(where: { $0.tokenHash == hash })?.permissions ?? []
            }, saveRegistration: { [weak self] registration in
                guard let self else { return }
                if !self.oauthRegistrations.contains(where: { $0.clientID == registration.clientID }), self.oauthRegistrations.count < 100 {
                    self.oauthRegistrations.append(registration); self.save()
                }
            }, rpc: { [weak self] token, request in
                guard let self else { return .object(["state": .string("unauthorized")]) }
                return await self.handle(.init(operation: "rpc", token: token, payload: request))
            })
            self.oauth = oauth
            try httpServer.start(port: httpPort) { [weak self, weak oauth] request in
                guard let self, let oauth else { return .failure("access_disabled", status: 503) }
                return await self.handleHTTP(request, oauth: oauth)
            }
            enabled = true; listening = true; error = nil
        } catch { self.error = error.localizedDescription; enabled = false; listening = false; server.stop(); httpServer.stop(); oauth = nil }
    }

    private func handleHTTP(_ request: AgentHTTPRequest, oauth: AgentOAuth) async -> AgentHTTPResponse {
        guard enabled, listening, self.oauth === oauth else { return .failure("access_disabled", status: 503) }
        return await oauth.handle(request)
    }

    func approve(_ id: UUID, role: AgentRole, name: String) {
        guard enabled, let pairing = pairings.first(where: { $0.id == id }), Date().timeIntervalSince(pairing.createdAt) < 600,
              sessions.count < 100 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions.append(AgentSession(name: String((trimmed.isEmpty ? pairing.client : trimmed).prefix(100)), tokenHash: pairing.tokenHash, role: role, requestedPermissions: pairing.requestedPermissions, oauthClientID: pairing.oauthClientID, connection: pairing.connection))
        pairings.removeAll { $0.id == id }
        appendAudit(session: pairing.client, action: "Approved \(role.title)", blocked: false)
        save()
    }
    func deny(_ id: UUID) {
        if let p = pairings.first(where: { $0.id == id }) { deniedHashes.insert(p.tokenHash) }
        pairings.removeAll { $0.id == id }
        if deniedHashes.count > 100 { deniedHashes.removeAll() }
    }
    func revoke(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].revokedAt = Date()
        for i in reviews.indices where reviews[i].sessionID == id && reviews[i].pending {
            reviews[i].pending = false; reviews[i].outcome = "Refused: session revoked"
        }
        _ = validateStagedPermissions()
        appendAudit(session: sessions[index].name, action: "Access revoked", blocked: false); save()
    }
    func setRole(_ id: UUID, role: AgentRole) {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.revokedAt == nil }) else { return }
        sessions[index].role = role; _ = validateStagedPermissions(); save()
    }
    func forgetRevoked() {
        let revokedClients = Set(sessions.filter { $0.revokedAt != nil }.compactMap(\.oauthClientID))
        let activeClients = Set(sessions.filter { $0.revokedAt == nil }.compactMap(\.oauthClientID))
        let forgottenClients = revokedClients.subtracting(activeClients)
        sessions.removeAll { $0.revokedAt != nil }
        oauthRegistrations.removeAll { forgottenClients.contains($0.clientID) }
        oauth?.forgetRegistrations(forgottenClients)
        pairings.removeAll { $0.oauthClientID.map(forgottenClients.contains) == true }
        save()
    }
    func approveCurrentRoot() {
        guard let root = explorer?.scan?.rootPath, approvedRoots.count < 32 else { return }
        let canonical = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        if !approvedRoots.contains(canonical) { approvedRoots.append(canonical); save() }
    }
    func addToClaudeDesktop() {
        guard !extensionWorking else { return }
        extensionWorking = true
        let helper = URL(fileURLWithPath: helperPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddy-Claude-\(UUID().uuidString)")
        Task {
            defer { extensionWorking = false }
            do {
                let file = try await Task.detached(priority: .utility) { try AgentExtensionBuilder.build(helper: helper, directory: directory) }.value
                extensionURL = file
                if !NSWorkspace.shared.open(file) { error = "Extension created. Open the file in Claude Desktop to review and install it." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func removeRoot(_ root: String) { approvedRoots.removeAll { $0 == root }; save() }
    func skipReview(_ id: UUID) {
        guard let i = reviews.firstIndex(where: { $0.id == id && $0.pending }) else { return }
        reviews[i].pending = false; reviews[i].outcome = "Skipped by owner"; save()
    }
    func review(_ id: UUID) {
        guard let i = reviews.firstIndex(where: { $0.id == id && $0.pending }), let m = explorer, !m.busy, !m.isScanning, let scan = m.scan else { return }
        let request = reviews[i]
        let permission = request.permanent ? "request_permanent" : "request_trash"
        guard sessions.contains(where: { $0.id == request.sessionID && $0.permissions.contains(permission) }) else {
            reviews[i].pending = false; reviews[i].outcome = "Refused: permission revoked"; save(); return
        }
        guard let node = scan.nodes.first(where: { $0.device == request.device && $0.inode == request.inode && scan.url(for: $0.id).path == request.path }), node.parent != nil else {
            reviews[i].pending = false; reviews[i].outcome = "Refused: scan or item identity changed; scan again"; save(); return
        }
        if m.hasAncestor(node.id, in: m.staged) {
            reviews[i].pending = false
            reviews[i].outcome = "Already covered by native Cleanup review. Existing staging is unchanged."
            save(); return
        }
        // Native action only. The existing preflight and Cleanup confirmation
        // remain authoritative. RPC has no route to trashStaged/deleteStaged.
        pendingStaging[node.id] = request.id
        m.stage(node.id, authorization: { [weak self] in
            guard let self else { return false }
            return self.pendingStaging[node.id] == request.id && self.policyHealthy &&
                self.sessions.contains { $0.id == request.sessionID && $0.permissions.contains(permission) }
        }, didStage: { [weak self] in
            self?.pendingStaging.removeValue(forKey: node.id)
            self?.stagedRequests[node.id] = request.id
        }, didFinish: { [weak self] in
            if self?.pendingStaging[node.id] == request.id { self?.pendingStaging.removeValue(forKey: node.id) }
        })
        m.workspace = .cleanup
        reviews[i].pending = false
        reviews[i].outcome = "Sent to native Cleanup preflight. Nothing removed; verify staging and choose the cleanup action there."
        save()
    }

    func unstageRequest(_ nodeID: Int) {
        pendingStaging.removeValue(forKey: nodeID)
        stagedRequests.removeValue(forKey: nodeID)
    }

    func clearStagedRequests() {
        let ownedIDs = Array(stagedRequests.keys)
        pendingStaging.removeAll()
        stagedRequests.removeAll()
        for id in ownedIDs { explorer?.unstage(id) }
    }

    /// Call immediately before native Cleanup preflight and again before its
    /// execution. Session revocation/role reductions also invalidate staging.
    @discardableResult func validateStagedPermissions() -> Bool {
        guard let m = explorer else { return false }
        var valid = true
        for (nodeID, requestID) in pendingStaging {
            guard let request = reviews.first(where: { $0.id == requestID }), policyHealthy,
                  sessions.contains(where: { $0.id == request.sessionID && $0.permissions.contains(request.permanent ? "request_permanent" : "request_trash") }) else {
                m.unstage(nodeID); valid = false; continue
            }
        }
        for (nodeID, requestID) in stagedRequests {
            guard m.staged.contains(nodeID) else { stagedRequests.removeValue(forKey: nodeID); continue }
            guard let request = reviews.first(where: { $0.id == requestID }) else { m.unstage(nodeID); stagedRequests.removeValue(forKey: nodeID); valid = false; continue }
            let permitted = policyHealthy && sessions.contains { $0.id == request.sessionID && $0.permissions.contains(request.permanent ? "request_permanent" : "request_trash") }
            let matches = m.scan.map { scan in scan.nodes.indices.contains(nodeID) && scan.nodes[nodeID].device == request.device && scan.nodes[nodeID].inode == request.inode && scan.url(for: nodeID).path == request.path } ?? false
            if !permitted || !matches {
                m.unstage(nodeID); valid = false
                stagedRequests.removeValue(forKey: nodeID)
            }
        }
        return valid
    }

    func handle(_ request: AgentBridgeRequest) async -> AgentJSON {
        guard enabled, listening, policyHealthy else { return .object(["error": .string("Agent access is off.")]) }
        pairings.removeAll { Date().timeIntervalSince($0.createdAt) >= 600 }
        switch request.operation {
        case "pair":
            guard let client = request.payload["client"].string, !client.isEmpty, client.utf8.count <= 100,
                  let hash = request.payload["tokenHash"].string, AgentSecurity.validHash(hash),
                  let requested = request.payload["permissions"].array, requested.count <= 5,
                  requested.allSatisfy({ $0.string != nil && AgentRole.admin.permissions.contains($0.string!) }) else {
                return .object(["error": .string("Invalid pairing request.")])
            }
            if deniedHashes.contains(hash) { return .object(["state": .string("denied")]) }
            if sessions.contains(where: { $0.tokenHash == hash && $0.revokedAt == nil }) { return .object(["state": .string("approved")]) }
            if !pairings.contains(where: { $0.tokenHash == hash }) {
                guard pairings.count < 20 else { return .object(["error": .string("Too many pending approvals; review them in StorageDaddy.")]) }
                pairings.append(AgentPairing(client: client, tokenHash: hash, requestedPermissions: Set(requested.compactMap(\.string))))
            }
            return .object(["state": .string("pending"), "message": .string("Approve this client in StorageDaddy → AI Agents.")])
        case "session", "rpc":
            guard let token = request.token, token.utf8.count <= 100,
                  let index = sessions.firstIndex(where: { $0.tokenHash == AgentSecurity.hash(token) && $0.revokedAt == nil }) else {
                return .object(["state": .string("unauthorized"), "error": .string("Native approval is required or this session was revoked.")])
            }
            let session = sessions[index]
            if request.operation == "session" { return .object(["state": .string("approved"), "permissions": .array(session.permissions.sorted().map(AgentJSON.string))]) }
            return await AgentMCP.respond(request.payload, permissions: session.permissions) { [weak self] name, arguments in
                guard let self else { throw AgentSecurity.failure("StorageDaddy closed.") }
                return try await self.call(name, arguments: arguments, sessionID: session.id)
            }
        default: return .object(["error": .string("Unknown bridge operation.")])
        }
    }

    private func call(_ name: String, arguments a: AgentJSON, sessionID: UUID) async throws -> AgentJSON {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), sessions[i].revokedAt == nil,
              let tool = AgentTool.catalog.first(where: { $0.name == name }), sessions[i].permissions.contains(tool.permission) else {
            if let i = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[i].blocked += 1; appendAudit(session: sessions[i].name, action: String(name.prefix(100)) + " · Permission denied", blocked: true); save() }
            throw AgentSecurity.failure("This session lacks permission. Review its role in StorageDaddy → AI Agents.")
        }
        guard let args = a.object, Set(args.keys).isSubset(of: Set(tool.properties.keys)), tool.required.allSatisfy({ args[$0] != nil }) else { throw AgentSecurity.failure("Invalid tool arguments.") }
        guard let m = explorer else { throw AgentSecurity.failure("StorageDaddy window is unavailable.") }
        let session = sessions[i]
        let limit = min(200, max(1, a["limit"].int ?? 50)), offset = max(0, a["offset"].int ?? 0)
        sessions[i].lastAction = name; sessions[i].lastActionAt = Date()
        appendAudit(session: session.name, action: name, blocked: false); save()
        if name == "storagedaddy_status" {
            let measuredAt = Date()
            let drives = await Task.detached(priority: .utility) { DriveMonitor.readCapacities() }.value
            return .object(["agent": .string(session.name), "role": .string(session.role.title), "permissions": .array(session.permissions.sorted().map(AgentJSON.string)),
                            "scanning": .bool(m.isScanning), "busy": .bool(m.busy), "workspace": .string(m.workspace.rawValue), "scanRoot": m.scan.map { .string($0.rootPath) } ?? .null,
                            "drivesMeasuredAt": .string(measuredAt.ISO8601Format()), "drives": .array(drives.map { .object(["id": .string($0.id), "name": .string($0.name), "freeBytes": .integer($0.freeBytes), "capacityBytes": .integer($0.totalBytes)]) }),
                            "scanFreeBytes": m.volumeFree.map(AgentJSON.integer) ?? .null, "approvedScanRoots": .array(approvedRoots.map(AgentJSON.string)),
                            "requests": try .encode(reviews.filter { $0.sessionID == sessionID }), "procedures": .array([.string("skill://storagedaddy/free-up-space"), .string("skill://storagedaddy/investigate-growth")])])
        }
        if name == "storagedaddy_read_skill", let skill = a["name"].string, let text = AgentMCP.skill(skill) { return .object(["procedure": .string(text)]) }
        if name == "storagedaddy_scan_history" {
            await m.refreshSnapshotHistory()
            return .array(m.savedSnapshots.prefix(limit).map { .object(["id": .string($0.id.uuidString), "root": .string($0.scan.rootPath), "savedAt": .string($0.savedAt.ISO8601Format()), "allocatedBytes": .integer($0.scan.nodes.first?.allocatedBytes ?? 0), "nodes": .integer($0.scan.nodes.count), "skipped": .integer($0.scan.skipped)]) })
        }
        if name == "storagedaddy_changes" {
            await m.refreshSnapshotHistory()
            guard let before = m.savedSnapshots.first(where: { $0.id.uuidString == a["before"].string }), let after = m.savedSnapshots.first(where: { $0.id.uuidString == a["after"].string }), before.scan.rootPath == after.scan.rootPath else { throw AgentSecurity.failure("Choose two saved scan IDs with the same root.") }
            let directory = m.snapshotDirectory, query = a["query"].string ?? ""
            return await Task.detached(priority: .utility) {
                if let diff = try? ScanFileIndex.compare(before: before, after: after, directory: directory, search: query, limit: limit) {
                    func entry(_ value: ScanFileEntry?) -> AgentJSON {
                        value.map { .object(["logicalBytes": .integer($0.logicalBytes), "allocatedBytes": .integer($0.allocatedBytes), "modified": .string($0.modified.ISO8601Format()), "symlink": .bool($0.isSymlink)]) } ?? .null
                    }
                    return .object(["coverage": .string("Per-file metadata index"), "partialCoverage": .bool(diff.partialCoverage), "changeCount": .integer(diff.changeCount), "truncated": .bool(diff.truncated),
                                    "logicalDelta": .integer(diff.logicalDelta), "allocatedDelta": .integer(diff.allocatedDelta),
                                    "changes": .array(diff.changes.map { .object(["path": .string($0.path), "kind": .string($0.kind.rawValue), "before": entry($0.before), "after": entry($0.after), "logicalDelta": .integer($0.logicalDelta), "allocatedDelta": .integer($0.allocatedDelta)]) })])
                }
                var old: [String: Int64] = [:], new: [String: Int64] = [:]
                for node in before.scan.nodes { old[before.scan.url(for: node.id).path] = node.allocatedBytes }
                for node in after.scan.nodes { new[after.scan.url(for: node.id).path] = node.allocatedBytes }
                let rows = Set(old.keys).union(new.keys).compactMap { path -> (String, Int64, Int64)? in
                    let b = old[path] ?? 0, a = new[path] ?? 0
                    return a == b || (!query.isEmpty && !path.localizedCaseInsensitiveContains(query)) ? nil : (path, b, a)
                }.sorted { abs(Double($0.2) - Double($0.1)) > abs(Double($1.2) - Double($1.1)) }
                return .object(["coverage": .string("Saved history coverage; compact snapshots contain top-level sizes only."), "changes": .array(rows.prefix(limit).map { .object(["path": .string($0.0), "beforeBytes": .integer($0.1), "afterBytes": .integer($0.2), "deltaBytes": .number(Double($0.2) - Double($0.1))]) })])
            }.value
        }
        if name == "storagedaddy_start_scan" {
            guard !m.busy, !m.isScanning, m.macTools?.isBusy != true, m.staged.isEmpty,
                  let raw = a["root"].string, raw.hasPrefix("/"), !raw.utf8.contains(0) else { throw AgentSecurity.failure("Finish active work and native Cleanup review first.") }
            let root = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
            guard approvedRoots.contains(root.path) else { throw AgentSecurity.failure("Approve this exact scan root in StorageDaddy → AI Agents first.") }
            scanOwner = nil
            m.start(root, notifyOnCompletion: false)
            if let version = m.activeScanVersion { scanOwner = (sessionID, version) }
            return .object(["started": .bool(m.isScanning), "root": .string(root.path)])
        }
        if name == "storagedaddy_cancel_scan" {
            guard scanOwner?.sessionID == sessionID, let version = m.activeScanVersion, scanOwner?.version == version else { throw AgentSecurity.failure("This session does not own the current scan.") }
            m.cancel(); scanOwner = nil; return .object(["cancelRequested": .bool(true)])
        }
        if name == "storagedaddy_show" {
            guard !m.busy else { throw AgentSecurity.failure("A native storage operation is in progress.") }
            if let section = a["section"].string {
                guard let workspace = Workspace.allCases.first(where: { $0.rawValue.localizedCaseInsensitiveCompare(section) == .orderedSame }) else { throw AgentSecurity.failure("Unknown section. Use the workspace names from StorageDaddy.") }
                m.workspace = workspace
            }
            if let id = a["nodeID"].int, let scan = m.scan, scan.nodes.indices.contains(id) { m.openStorage(.explore); m.open(scan.nodes[id]) }
            return .object(["workspace": .string(m.workspace.rawValue)])
        }
        guard let scan = m.scan else { throw AgentSecurity.failure("Scan a location in StorageDaddy first.") }
        if name == "storagedaddy_measure_removal" {
            guard let raw = a["nodeIDs"].array, !raw.isEmpty, raw.count <= 20, raw.allSatisfy({ $0.int != nil && scan.nodes.indices.contains($0.int!) && scan.nodes[$0.int!].parent != nil }) else { throw AgentSecurity.failure("Choose 1–20 existing non-root scan node IDs.") }
            let paths = Array(Set(raw.compactMap(\.int))).sorted().map { scan.url(for: $0) }
            let excluded = m.excludedFolders
            let worker = Task.detached(priority: .utility) { try RemovalMeasurement.measure(paths: paths, excludedFolders: excluded) }
            let report = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            return try .encode(report)
        }
        if name == "storagedaddy_reveal_path" {
            guard let id = a["nodeID"].int, scan.nodes.indices.contains(id) else { throw AgentSecurity.failure("Choose an existing scan node ID.") }
            m.reveal(id); return .object(["revealed": .bool(true)])
        }
        if name == "storagedaddy_find_duplicates" {
            guard !m.busy, !m.duplicatesLoading else { throw AgentSecurity.failure("A scan or duplicate search is already running.") }
            m.findDuplicates(); return .object(["started": .bool(m.duplicatesLoading)])
        }
        if name == "storagedaddy_duplicates" { return .object(["running": .bool(m.duplicatesLoading), "searched": .bool(m.duplicatesSearched), "groups": .array(m.duplicateGroups.prefix(limit).map { .object(["id": .string($0.id), "nodeIDs": .array($0.nodeIDs.map(AgentJSON.integer)), "members": .array($0.nodeIDs.compactMap { id in
            guard scan.nodes.indices.contains(id) else { return nil }
            let node = scan.nodes[id]
            return .object(["nodeID": .integer(id), "path": .string(scan.url(for: id).path), "modified": .string(node.modified.ISO8601Format()), "logicalBytes": .integer(node.logicalBytes), "allocatedBytes": .integer(node.allocatedBytes)])
        }), "wastedBytes": .integer($0.wastedBytes)]) })]) }
        if name == "storagedaddy_move_to_trash" || name == "storagedaddy_delete_permanently" {
            guard let ids = a["nodeIDs"].array, !ids.isEmpty, ids.count <= 20, ids.allSatisfy({ $0.int != nil }),
                  let reason = a["reason"].string, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 1000,
                  waitingReviewCount + ids.count <= 500 else { throw AgentSecurity.failure("Provide 1–20 scan node IDs and a brief reason, or review the waiting queue first.") }
            var proposed: [AgentReviewRequest] = []
            for id in Set(ids.compactMap(\.int)).sorted() {
                guard scan.nodes.indices.contains(id), scan.nodes[id].parent != nil else { throw AgentSecurity.failure("Scan roots and unknown nodes cannot be requested.") }
                let node = scan.nodes[id], path = scan.url(for: id).path
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let protected = ["/", home, home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Library", "/Applications", "/System", "/Library", "/Users", Bundle.main.bundlePath]
                guard !protected.contains(where: { canonical == $0 || ($0 != "/" && $0.hasPrefix(canonical + "/")) }),
                      !["/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/db"].contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }),
                      !FolderExclusions(paths: m.excludedFolders).blocksCleanup(URL(fileURLWithPath: canonical)) else {
                    appendAudit(session: session.name, action: name + " · Protected location refused", blocked: true); save(); throw AgentSecurity.failure("A protected or excluded path was refused. Nothing was removed.")
                }
                let request = AgentReviewRequest(sessionID: sessionID, agent: session.name, reason: reason, permanent: name.hasSuffix("delete_permanently"), path: path, device: node.device, inode: node.inode, scanStarted: scan.started)
                proposed.append(request)
            }
            reviews.append(contentsOf: proposed)
            save()
            return .object(["requestIDs": .array(proposed.map { .string($0.id.uuidString) }), "state": .string("Waiting for owner review in StorageDaddy → AI Agents. Nothing staged, approved or removed. Native Cleanup determines the final action.")])
        }
        let quickIDs = Set(m.quickWinNodes.map(\.id)), developerIDs = Set(m.developerGroups.flatMap(\.rootIDs))
        let detail = name
        return try await Task.detached(priority: .utility) {
            func row(_ node: DiskNode) -> AgentJSON { .object(["nodeID": .integer(node.id), "path": .string(scan.url(for: node.id).path), "directory": .bool(node.isDirectory), "logicalBytes": .integer(node.logicalBytes), "attributedBytes": .integer(node.allocatedBytes), "modified": .string(node.modified.ISO8601Format())]) }
            var nodes: [DiskNode]
            switch detail {
            case "storagedaddy_scan_summary":
                let top = scan.nodes.dropFirst().sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(limit)
                return .object(["root": .string(scan.rootPath), "scanStarted": .string(scan.started.ISO8601Format()), "allocatedBytes": .integer(scan.nodes.first?.allocatedBytes ?? 0), "logicalBytes": .integer(scan.nodes.first?.logicalBytes ?? 0), "skipped": .integer(scan.skipped), "largest": .array(top.map(row)), "accounting": .string("Attributed scan allocation; APFS sharing and snapshots can reduce actual reclaimed space.")])
            case "storagedaddy_list_folder":
                guard let id = a["nodeID"].int, scan.nodes.indices.contains(id), scan.nodes[id].isDirectory else { throw AgentSecurity.failure("Choose a scanned directory node ID.") }
                nodes = scan.nodes[id].children.map { scan.nodes[$0] }
            case "storagedaddy_search_files":
                let query = a["query"].string ?? "", ext = a["extension"].string?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
                nodes = scan.nodes.filter { node in
                    guard node.allocatedBytes >= Int64(a["minimumBytes"].int ?? 0) else { return false }
                    if !ext.isEmpty && (node.isDirectory || URL(fileURLWithPath: node.name).pathExtension.lowercased() != ext) { return false }
                    return query.isEmpty || scan.url(for: node.id).path.localizedCaseInsensitiveContains(query)
                }
            case "storagedaddy_cleanup_suggestions": nodes = scan.nodes.filter { quickIDs.contains($0.id) }
            case "storagedaddy_dev_artifacts": nodes = scan.nodes.filter { developerIDs.contains($0.id) }
            default: throw AgentSecurity.failure("Invalid tool arguments or unsupported tool.")
            }
            nodes.sort { $0.allocatedBytes > $1.allocatedBytes }
            return .object(["total": .integer(nodes.count), "offset": .integer(offset), "items": .array(nodes.dropFirst(min(offset, nodes.count)).prefix(limit).map(row))])
        }.value
    }

    private func appendAudit(session: String, action: String, blocked: Bool) {
        audit.insert(AgentAuditEntry(session: session, action: action, blocked: blocked), at: 0)
        audit = Array(audit.prefix(200))
    }
    private func save() {
        let pending = reviews.filter(\.pending)
        let decided = reviews.filter { !$0.pending && Date().timeIntervalSince($0.requestedAt) < 7 * 86400 }
            .sorted { $0.requestedAt > $1.requestedAt }.prefix(200)
        reviews = (Array(pending.prefix(500)) + Array(decided)).sorted { $0.requestedAt < $1.requestedAt }
        do { try AgentSecurity.save(AgentPolicy(sessions: sessions, reviews: reviews, audit: audit, approvedRoots: approvedRoots, oauthRegistrations: oauthRegistrations), to: directory.appendingPathComponent("agent-policy.json")) }
        catch { self.error = "Could not persist agent policy. Access disabled. \(error.localizedDescription)"; enabled = false; listening = false; policyHealthy = false; server.stop(); httpServer.stop(); oauth = nil }
    }
}
