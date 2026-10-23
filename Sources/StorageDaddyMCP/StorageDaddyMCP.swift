import Foundation
import Security
import AgentBridge

private final class MCPBridge: @unchecked Sendable {
    private let lock = NSLock(), outputLock = NSLock()
    private var token: String?
    private var candidate: String?
    private var client = "MCP client"
    private var started = false
    private var stopped = false
    private var state = "Open StorageDaddy and enable AI Agents."
    private var currentPermissions: Set<String> = []
    private var firstToolList = true
    private let path: String
    private let ephemeral: Bool

    init(path: String, ephemeral: Bool) { self.path = path; self.ephemeral = ephemeral }

    func emit(_ value: AgentJSON) {
        guard value != .null, let data = try? JSONEncoder().encode(value), data.count <= AgentSocketClient.maximumMessageBytes else { return }
        outputLock.withLock {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    func start(client: String) {
        guard lock.withLock({ if started { return false }; started = true; self.client = String(client.prefix(100)); return true }) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let saved = ephemeral ? nil : try credential(read: true)
                if let saved { lock.withLock { token = saved } }
                else { let fresh = try AgentSecurity.randomToken(); lock.withLock { candidate = fresh } }
            } catch {
                lock.withLock { state = "Secure credential storage is unavailable. Unlock Keychain, or reconnect with --ephemeral to approve this connection without saving a token."; stopped = true }
                return
            }
            let deadline = Date().addingTimeInterval(600)
            var announced: Set<String> = []
            while Date() < deadline || lock.withLock({ token != nil }) {
                if lock.withLock({ stopped }) { return }
                do {
                    if let active = lock.withLock({ token }) {
                        let response = try AgentSocketClient.request(.init(operation: "session", token: active), path: path)
                        if response["state"].string == "approved" {
                            let permissions = Set(response["permissions"].array?.compactMap(\.string) ?? [])
                            lock.withLock { currentPermissions = permissions; state = "Connected" }
                            if permissions != announced { emit(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")])); announced = permissions }
                        } else {
                            if !ephemeral { _ = try? credential(read: false, remove: true) }
                            lock.withLock { token = nil; currentPermissions = []; state = "This session was revoked or is no longer approved. Reconnect to request new native approval."; stopped = true }
                            emit(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]))
                            return
                        }
                    } else if let pending = lock.withLock({ candidate }) {
                        let response = try AgentSocketClient.request(.init(operation: "pair", payload: .object(["client": .string(lock.withLock { client }), "tokenHash": .string(AgentSecurity.hash(pending)), "permissions": .array(AgentRole.admin.permissions.sorted().map(AgentJSON.string))])), path: path)
                        switch response["state"].string {
                        case "approved":
                            let session = try AgentSocketClient.request(.init(operation: "session", token: pending), path: path)
                            guard session["state"].string == "approved" else { throw AgentSecurity.failure("Approval changed before the session connected.") }
                            let permissions = Set(session["permissions"].array?.compactMap(\.string) ?? [])
                            if !ephemeral { _ = try credential(read: false, value: pending) }
                            lock.withLock { token = pending; candidate = nil; currentPermissions = permissions; state = "Connected" }
                            if permissions != announced { emit(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")])); announced = permissions }
                        case "denied": lock.withLock { state = "Native approval was denied. Reconnect only when the owner wants to try again."; stopped = true }; return
                        default: lock.withLock { state = response["message"].string ?? response["error"].string ?? "Waiting for approval in StorageDaddy → AI Agents." }
                        }
                    }
                } catch { lock.withLock { state = "StorageDaddy is unavailable. Open the app and enable AI Agents; no action was retried." } }
                Thread.sleep(forTimeInterval: 1)
            }
            lock.withLock { state = "Native approval timed out after ten minutes. Reconnect to request approval again."; stopped = true }
        }
    }

    func response(_ request: AgentJSON) async -> AgentJSON {
        if request["method"].string == "initialize" {
            start(client: request["params"]["clientInfo"]["name"].string ?? "MCP client")
            return AgentMCP.handshake(id: request["id"])
        }
        if request["method"].string == "tools/list" {
            let needsInitialApproval = lock.withLock {
                let initial = firstToolList; firstToolList = false
                let name = client.lowercased()
                return initial && name.contains("claude") && !name.contains("code")
            }
            if needsInitialApproval {
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline && lock.withLock({ currentPermissions.isEmpty && !stopped }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        let permissions = lock.withLock { currentPermissions }
        if request["method"].string == "tools/call", let active = lock.withLock({ token }) {
            do {
                let response = try AgentSocketClient.request(.init(operation: "rpc", token: active, payload: request), path: path)
                if response["state"].string == "unauthorized" { return AgentMCP.result(id: request["id"], AgentMCP.toolResult(.object(["error": .string("Session revoked. Reconnect and approve in StorageDaddy.")]), isError: true)) }
                return response
            } catch { return AgentMCP.result(id: request["id"], AgentMCP.toolResult(.object(["error": .string("StorageDaddy disconnected. The call was not retried; check native status before trying again.")]), isError: true)) }
        }
        return await AgentMCP.respond(request, permissions: permissions) { [self] name, _ in
            if name == "storagedaddy_status" { return .object(["connection": .string(lock.withLock { state }), "approved": .bool(lock.withLock { token != nil }), "nextStep": .string("Open StorageDaddy → AI Agents to enable access and review the client request.")]) }
            throw AgentSecurity.failure("Native approval is required. Read storagedaddy_status and ask the owner to review the request in StorageDaddy.")
        }
    }

    private func credential(read: Bool, value: String? = nil, remove: Bool = false) throws -> String? {
        let account = AgentSecurity.hash(lock.withLock { client } + "|" + path)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.sarthak.StorageDaddy.MCP", kSecAttrAccount as String: account]
        if remove { SecItemDelete(base as CFDictionary); return nil }
        if read {
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), token.count == 43 else { throw AgentSecurity.failure("Keychain is unavailable.") }
            return token
        }
        guard let value else { return nil }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(base as CFDictionary)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AgentSecurity.failure("Cannot save the approval in Keychain.") }
        return nil
    }
}

@main enum StorageDaddyMCP {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        var path = AgentSecurity.socketPath
        var ephemeral = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--ephemeral": ephemeral = true
            case "--socket":
                i += 1
                guard i < args.count, args[i].hasPrefix("/") else { return }
                path = args[i]
            case "--help":
                FileHandle.standardError.write(Data("storagedaddy-mcp [--ephemeral] [--socket /absolute/private/agent.sock] [--forget]\nCredentials are saved only in macOS Keychain. Approve clients in StorageDaddy.\n".utf8)); return
            case "--forget":
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.sarthak.StorageDaddy.MCP"]
                let result = SecItemDelete(query as CFDictionary)
                FileHandle.standardError.write(Data((result == errSecSuccess || result == errSecItemNotFound ? "Saved StorageDaddy helper credentials forgotten. Revoke native sessions in StorageDaddy to invalidate access.\n" : "Keychain is unavailable; credentials were not forgotten.\n").utf8)); return
            default: FileHandle.standardError.write(Data("Unknown option. Use --help.\n".utf8)); return
            }
            i += 1
        }
        let bridge = MCPBridge(path: path, ephemeral: ephemeral)
        var buffered = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            buffered.append(chunk)
            while let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end)
                buffered.removeSubrange(...end)
                guard line.count <= AgentSocketClient.maximumMessageBytes else {
                    bridge.emit(AgentMCP.error(id: .null, code: -32700, message: "Request exceeds 1 MiB.")); return
                }
                do { bridge.emit(await bridge.response(try JSONDecoder().decode(AgentJSON.self, from: line))) }
                catch { bridge.emit(AgentMCP.error(id: .null, code: -32700, message: "Invalid JSON.")) }
            }
            guard buffered.count <= AgentSocketClient.maximumMessageBytes else { bridge.emit(AgentMCP.error(id: .null, code: -32700, message: "Request exceeds 1 MiB.")); return }
        }
    }
}
