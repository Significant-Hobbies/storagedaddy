import Foundation
import Testing
@testable import StorageDaddy

@Test func hostRanksOnlyMeasuredReviewableCandidatesOnTheStartupDisk() {
    let root = URL(fileURLWithPath: "/fixture")
    let scope = DeveloperCleanupReview.Scope(url: root)
    func item(_ node: Int, _ path: String, _ bytes: Int64, device: UInt64 = 3,
              protected: Bool = false, permanent: Bool = true) -> DeveloperCleanupReview.Item {
        .init(id: .init(scope: 0, node: node), path: path, allocatedBytes: bytes,
              keptReason: protected ? "In use" : nil, canDeletePermanently: permanent, device: device, inode: UInt64(node + 1))
    }
    let items = [item(0, "/fixture/build", 20), item(1, "/fixture/node_modules", 40),
                 item(2, "/fixture/in-use", 200, protected: true), item(3, "/fixture/external", 300, device: 4),
                 item(4, "/fixture/trash-only", 400, permanent: false), item(5, "/fixture/applied", 500)]
    var plan = DeveloperCleanupReview(scopes: [scope], items: items)
    #expect(StorageWorkspaceCandidate.ranked(in: plan, outcome: nil).isEmpty)
    plan.startupDevice = 3
    let outcome = DeveloperCleanupReview.Outcome(deleted: [items[5].id])
    let rows = StorageWorkspaceCandidate.ranked(in: plan, outcome: outcome)
    #expect(rows.map(\.path) == ["/fixture/node_modules", "/fixture/build"])
    #expect(rows.first?.kind == "Installed dependencies")
    #expect(rows.map(\.allocatedBytes) == [40, 20])
}

@MainActor @Test func hostNavigatesNativeStorageWithoutStartingAgentAccessOrScans() {
    let sourceName = "storage-source-" + UUID().uuidString, hostName = "storage-host-" + UUID().uuidString
    let source = UserDefaults(suiteName: sourceName)!, host = UserDefaults(suiteName: hostName)!
    defer {
        source.removePersistentDomain(forName: sourceName)
        host.removePersistentDomain(forName: hostName)
    }
    source.set(["/fixture/protected"], forKey: "excludedFolders")
    let session = StorageWorkspaceSession(defaults: host, standalone: source,
        agentDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(session.model.excludedFolders == ["/fixture/protected"])
    source.set(["/fixture/protected", "/fixture/new-exclusion"], forKey: "excludedFolders")
    for (route, expected): (String, Workspace) in [
        ("disk-explorer-file-search", .explore), ("files", .findFiles),
        ("worktrees", .developer), ("duplicates", .duplicates), ("app-data", .appData),
        ("ai-sessions-archives", .aiSessions), ("history", .snapshots), ("applications", .applications),
        ("mac-controls", .macControls), ("drive-monitoring", .driveMonitoring), ("agent-access", .agents)
    ] {
        session.activate(route)
        #expect(session.model.workspace == expected)
    }
    #expect(session.cleanupCandidates.isEmpty)
    #expect(session.cleanupMeasuredBytes == nil)
    #expect(session.model.excludedFolders == ["/fixture/protected", "/fixture/new-exclusion"])
    #expect(!session.model.agentAccess.enabled)
    #expect(!session.model.agentAccess.listening)
    #expect(!session.model.busy)
    #expect(!session.model.isFindingStorageCulprits)
}
