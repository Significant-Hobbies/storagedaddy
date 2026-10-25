import Foundation
import Testing
import DiskCore
import AgentBridge
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct AgentAccessIntegrationTests {
    private struct Fixture {
        let directory: URL
        let root: URL
        let agentDirectory: URL
        let explorer: ExplorerModel
        let agents: AgentAccessModel
        let token: String
        let port: UInt16
        let nodeID: Int
    }

    private func fixture(role: AgentRole = .operator) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sd-native-agent-\(UUID())")
        let root = directory.appendingPathComponent("scan"), agentDirectory = directory.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(repeating: 7, count: 8192).write(to: root.appendingPathComponent("sample.bin"))
        let scan = try await DiskScanner.scan(root: root)
        let nodeID = try #require(scan.nodes.first(where: { $0.name == "sample.bin" })?.id)
        let explorer = ExplorerModel(); explorer.scan = scan
        let port = UInt16.random(in: 53000...54999)
        let agents = AgentAccessModel(explorer: explorer, directory: agentDirectory, httpPort: port)
        explorer.agentAccess = agents
        #expect(!agents.enabled)
        #expect(!agents.listening)
        agents.setEnabled(true)
        #expect(agents.listening, "\(agents.error ?? "No listener error")")
        let token = try AgentSecurity.randomToken()
        let paired = await agents.handle(.init(operation: "pair", payload: .object(["client": .string("Fixture agent"), "tokenHash": .string(AgentSecurity.hash(token)), "permissions": .array(AgentRole.admin.permissions.sorted().map(AgentJSON.string))])))
        #expect(paired["state"].string == "pending")
        let pairing = try #require(agents.pairings.first)
        agents.approve(pairing.id, role: role, name: "Fixture agent")
        return Fixture(directory: directory, root: root, agentDirectory: agentDirectory, explorer: explorer, agents: agents, token: token, port: port, nodeID: nodeID)
    }
    private func call(_ name: String, arguments: AgentJSON = .object([:]), fixture f: Fixture) async -> AgentJSON {
        await f.agents.handle(.init(operation: "rpc", token: f.token, payload: .object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("tools/call"), "params": .object(["name": .string("storagedaddy_" + name), "arguments": arguments])]))
        )
    }

    private func httpToken(_ f: Fixture, approvedName: String = "HTTP fixture") async throws -> String {
        let base = "http://127.0.0.1:\(f.port)"
        func fetch(_ target: String, method: String = "GET", body: Data? = nil, type: String? = nil) async throws -> Data {
            var request = URLRequest(url: URL(string: base + target)!)
            request.httpMethod = method; request.httpBody = body
            if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect(((response as? HTTPURLResponse)?.statusCode ?? 500) < 400)
            return data
        }
        let registration = try await fetch("/register", method: "POST", body: JSONEncoder().encode(AgentJSON.object(["client_name": .string("HTTP fixture"), "redirect_uris": .array([.string("http://127.0.0.1:56321/callback")]), "token_endpoint_auth_method": .string("none")])), type: "application/json")
        let client = try #require(JSONDecoder().decode(AgentJSON.self, from: registration)["client_id"].string)
        let verifier = String(repeating: "a", count: 64)
        var authorize = URLComponents(); authorize.path = "/authorize"
        authorize.queryItems = ["client_id": client, "response_type": "code", "redirect_uri": "http://127.0.0.1:56321/callback", "resource": base + "/mcp", "scope": "read", "code_challenge_method": "S256", "code_challenge": AgentOAuth.challenge(verifier), "state": "fixture"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let html = String(data: try await fetch(authorize.string!), encoding: .utf8)!
        let id = html.components(separatedBy: "/authorization-result?id=")[1].components(separatedBy: "'")[0]
        let pairing = try #require(f.agents.pairings.first(where: { $0.client == "HTTP fixture" }))
        f.agents.approve(pairing.id, role: .explorer, name: approvedName)
        let ready = try await fetch("/authorization-result?id=" + id)
        let redirect = try #require(JSONDecoder().decode(AgentJSON.self, from: ready)["redirect"].string)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
        var form = URLComponents()
        form.queryItems = ["grant_type": "authorization_code", "client_id": client, "code": code, "redirect_uri": "http://127.0.0.1:56321/callback", "resource": base + "/mcp", "code_verifier": verifier].map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await fetch("/token", method: "POST", body: Data(form.percentEncodedQuery!.utf8), type: "application/x-www-form-urlencoded")
        return try #require(JSONDecoder().decode(AgentJSON.self, from: data)["access_token"].string)
    }

    @Test func requestQueuesWithoutStagingAndRevocationBlocksAsyncStaging() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        let response = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Fixture review only")]), fixture: f)
        #expect(response["result"]["isError"].bool == false)
        #expect(f.explorer.staged.isEmpty)
        let review = try #require(f.agents.reviews.first)
        f.agents.review(review.id)
        let session = try #require(f.agents.sessions.first)
        // Revoke before the asynchronous native preflight has completed.
        f.agents.revoke(session.id)
        for _ in 0..<200 {
            await Task.yield()
            if !f.explorer.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.agents.validateStagedPermissions())
        #expect(f.explorer.staged.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
        #expect(f.explorer.lastTrashedURLs.isEmpty)
        #expect(f.explorer.lastPermanentlyDeletedCount == 0)
    }

    private func waitForReview(_ f: Fixture) async throws {
        for _ in 0..<500 {
            if !f.explorer.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!f.explorer.busy)
    }

    @Test func revokedOrUnstagedRequestsDoNotOwnLaterNativeCleanup() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        _ = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Lifecycle fixture")]), fixture: f)
        f.agents.review(try #require(f.agents.reviews.first?.id))
        try await waitForReview(f)
        #expect(f.explorer.staged.contains(f.nodeID))
        f.explorer.unstage(f.nodeID)
        f.agents.revoke(try #require(f.agents.sessions.first?.id))
        f.explorer.stage(f.nodeID)
        try await waitForReview(f)
        #expect(f.agents.validateStagedPermissions())
        #expect(f.explorer.staged.contains(f.nodeID))
    }

    @Test func agentReviewCannotTakeOverAnExistingNativeCleanupItem() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        f.explorer.stage(f.nodeID)
        try await waitForReview(f)
        #expect(f.explorer.staged.contains(f.nodeID))
        _ = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Already staged fixture")]), fixture: f)
        f.agents.review(try #require(f.agents.reviews.first?.id))
        try await waitForReview(f)
        f.agents.revoke(try #require(f.agents.sessions.first?.id))
        #expect(f.agents.validateStagedPermissions())
        #expect(f.explorer.staged.contains(f.nodeID))
    }

    @Test(arguments: [false, true]) func overlappingAgentReviewKeepsOwnerStaging(_ ownerStagesParent: Bool) async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        let parent = f.root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("sample.bin"), to: parent.appendingPathComponent("sample.bin"))
        let scan = try await DiskScanner.scan(root: f.root)
        f.explorer.scan = scan
        let childID = try #require(scan.nodes.first { $0.name == "sample.bin" }?.id)
        let parentID = try #require(scan.nodes.first { $0.name == "parent" }?.id)
        let ownerID = ownerStagesParent ? parentID : childID
        let requestedID = ownerStagesParent ? childID : parentID
        f.explorer.stage(ownerID)
        try await waitForReview(f)
        #expect(f.explorer.staged.contains(ownerID))
        _ = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(requestedID)]), "reason": .string("Parent overlap fixture")]), fixture: f)
        f.agents.review(try #require(f.agents.reviews.first?.id))
        try await waitForReview(f)
        f.agents.revoke(try #require(f.agents.sessions.first?.id))
        #expect(f.agents.validateStagedPermissions())
        #expect(f.explorer.staged == [ownerID])
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("sample.bin").path))
    }

    @Test func agentPreflightRechecksNativeStagingBeforeInsertion() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        _ = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Async native precedence fixture")]), fixture: f)
        f.agents.review(try #require(f.agents.reviews.first?.id))
        // Simulate native staging publishing while the agent's preflight awaits.
        f.explorer.staged.insert(f.nodeID)
        try await waitForReview(f)
        f.agents.revoke(try #require(f.agents.sessions.first?.id))
        #expect(f.agents.validateStagedPermissions())
        #expect(f.explorer.staged == [f.nodeID])
    }

    @Test func rescanReusedNodeIDDoesNotInheritAgentAttribution() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        _ = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Rescan fixture")]), fixture: f)
        f.agents.review(try #require(f.agents.reviews.first?.id))
        try await waitForReview(f)
        f.explorer.scan = try await DiskScanner.scan(root: f.root)
        f.explorer.stage(f.nodeID)
        try await waitForReview(f)
        f.agents.revoke(try #require(f.agents.sessions.first?.id))
        #expect(f.agents.validateStagedPermissions())
        #expect(f.explorer.staged.contains(f.nodeID))
    }

    @Test func cancelScanRequiresTheExactSuccessfullyStartedScan() async throws {
        let f = try await fixture()
        defer { f.explorer.cancel(); f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        f.agents.approveCurrentRoot()
        let started = await call("start_scan", arguments: .object(["root": .string(f.root.path)]), fixture: f)
        #expect(started["result"]["isError"].bool == false)
        f.explorer.cancel()
        f.explorer.start(f.root, notifyOnCompletion: false)
        let nativeVersion = try #require(f.explorer.activeScanVersion)
        let refused = await call("cancel_scan", fixture: f)
        #expect(refused["result"]["isError"].bool == true)
        #expect(f.explorer.activeScanVersion == nativeVersion)
        f.explorer.cancel()
        f.explorer.snapshotBusy = true
        let failed = await call("start_scan", arguments: .object(["root": .string(f.root.path)]), fixture: f)
        let failedText = try #require(failed["result"]["content"].array?.first?["text"].string)
        #expect(try JSONDecoder().decode(AgentJSON.self, from: Data(failedText.utf8))["started"].bool == false)
        f.explorer.snapshotBusy = false
        f.explorer.start(f.root, notifyOnCompletion: false)
        let laterVersion = try #require(f.explorer.activeScanVersion)
        let stillRefused = await call("cancel_scan", fixture: f)
        #expect(stillRefused["result"]["isError"].bool == true)
        #expect(f.explorer.activeScanVersion == laterVersion)
    }

    @Test func roleReductionRejectsWaitingReviewAndHiddenToolAttemptIsLogged() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        _ = await call("move_to_trash", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Role fixture")]), fixture: f)
        let review = try #require(f.agents.reviews.first), session = try #require(f.agents.sessions.first)
        f.agents.setRole(session.id, role: .explorer)
        f.agents.review(review.id)
        #expect(f.agents.reviews.first?.outcome.contains("permission revoked") == true)
        let blocked = await call("delete_permanently", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)]), "reason": .string("Denied fixture")]), fixture: f)
        #expect(blocked["result"]["isError"].bool == true)
        #expect(f.agents.audit.contains(where: { $0.blocked }))
        #expect(f.agents.sessions.first?.blocked == 1)
        #expect(f.explorer.staged.isEmpty)
    }

    @Test func forgettingRenamedOAuthSessionUsesClientIdentity() async throws {
        let f = try await fixture()
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        let firstToken = try await httpToken(f, approvedName: "Owner renamed client")
        let secondToken = try await httpToken(f)
        let revoked = try #require(f.agents.sessions.first { $0.tokenHash == AgentSecurity.hash(firstToken) })
        let active = try #require(f.agents.sessions.first { $0.tokenHash == AgentSecurity.hash(secondToken) })
        let revokedClient = try #require(revoked.oauthClientID)
        let activeClient = try #require(active.oauthClientID)
        #expect(revokedClient != activeClient)
        f.agents.revoke(revoked.id)
        f.agents.forgetRevoked()
        let saved = try JSONDecoder().decode(AgentJSON.self, from: Data(contentsOf: f.agentDirectory.appendingPathComponent("agent-policy.json")))
        let registrations = try #require(saved["oauthRegistrations"].array)
        #expect(!registrations.contains { $0["clientID"].string == revokedClient })
        #expect(registrations.contains { $0["clientID"].string == activeClient })
        #expect(f.agents.sessions.contains { $0.id == active.id })
        // Forgetting applies immediately to the listening OAuth instance too.
        for (client, expected) in [(revokedClient, 400), (activeClient, 200)] {
            var authorize = URLComponents(string: "http://127.0.0.1:\(f.port)/authorize")!
            authorize.queryItems = ["client_id": client, "response_type": "code", "redirect_uri": "http://127.0.0.1:56321/callback", "resource": "http://127.0.0.1:\(f.port)/mcp", "scope": "read", "code_challenge_method": "S256", "code_challenge": AgentOAuth.challenge(String(repeating: "a", count: 64))].map { URLQueryItem(name: $0.key, value: $0.value) }
            let (_, response) = try await URLSession.shared.data(from: #require(authorize.url))
            #expect((response as? HTTPURLResponse)?.statusCode == expected)
        }
    }

    @Test func actualSocketHTTPMetadataAndPersistenceRemainLocalAndOffAfterRestart() async throws {
        let f = try await fixture(role: .explorer)
        defer { f.agents.setEnabled(false); try? FileManager.default.removeItem(at: f.directory) }
        let socketPath = f.agents.socketPath, token = f.token
        let session = try await Task.detached {
            try AgentSocketClient.request(.init(operation: "session", token: token), path: socketPath)
        }.value
        #expect(session["state"].string == "approved")
        let oauthToken = try await httpToken(f)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(f.port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + oauthToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AgentJSON.object(["jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/call"), "params": .object(["name": .string("storagedaddy_list_folder"), "arguments": .object(["nodeID": .integer(0)])])]))
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let rpc = try JSONDecoder().decode(AgentJSON.self, from: data)
        #expect(rpc["result"]["isError"].bool == false)
        #expect(rpc.text.contains("sample.bin"))
        // This link did not exist in the saved scan. Live measurement must
        // account for the new external holder instead of returning stale totals.
        try FileManager.default.linkItem(at: f.root.appendingPathComponent("sample.bin"), to: f.directory.appendingPathComponent("external-link.bin"))
        let summary = await call("measure_removal", arguments: .object(["nodeIDs": .array([.integer(f.nodeID)])]), fixture: f)
        #expect(summary["result"]["isError"].bool == false)
        let measurementText = try #require(summary["result"]["content"].array?.first?["text"].string)
        let measurement = try JSONDecoder().decode(LiveRemovalReport.self, from: Data(measurementText.utf8))
        #expect(measurement.total.freesBytes == 0)
        #expect(measurement.total.heldElsewhereBytes > 0)
        #expect(measurement.measuredAt >= f.explorer.scan!.started)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
        f.agents.setEnabled(false)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        let restarted = AgentAccessModel(explorer: f.explorer, directory: f.agentDirectory, httpPort: f.port)
        #expect(!restarted.enabled)
        #expect(!restarted.listening)
        #expect(restarted.sessions.count == 2)
        #expect(restarted.pairings.isEmpty)
        let policyText = try String(contentsOf: f.agentDirectory.appendingPathComponent("agent-policy.json"), encoding: .utf8)
        #expect(!policyText.contains(f.token))
        #expect(!policyText.contains(oauthToken))
        #expect(policyText.contains(AgentSecurity.hash(f.token)))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
    }
}
