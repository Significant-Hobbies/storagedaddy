import Foundation

public enum AgentMCP {
    public static let protocolVersion = "2025-06-18"
    public static func result(id: AgentJSON, _ result: AgentJSON) -> AgentJSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    public static func error(id: AgentJSON, code: Int = -32602, message: String) -> AgentJSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .integer(code), "message": .string(message)])])
    }
    public static func toolResult(_ value: AgentJSON, isError: Bool = false) -> AgentJSON {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(value.text)])]), "isError": .bool(isError)])
    }
    public static func handshake(id: AgentJSON) -> AgentJSON {
        result(id: id, .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object(["tools": .object(["listChanged": .bool(true)]), "resources": .object([:]), "prompts": .object([:])]),
            "serverInfo": .object(["name": .string("storagedaddy"), "version": .string("1.0.0")]),
            "instructions": .string("Use StorageDaddy for local storage scans, large files, growth, caches and duplicates. Start with storagedaddy_status. Read free-up-space or investigate-growth before recommendations. Native approval is mandatory; removal tools only request review. Metadata stays on this Mac until your client reads it.")
        ]))
    }
    public static func respond(_ request: AgentJSON, permissions: Set<String>, call: @Sendable (String, AgentJSON) async throws -> AgentJSON) async -> AgentJSON {
        let id = request["id"]
        guard request["jsonrpc"].string == "2.0", let method = request["method"].string else { return error(id: id, code: -32600, message: "Invalid JSON-RPC request.") }
        switch method {
        case "initialize": return handshake(id: id)
        case "ping": return result(id: id, .object([:]))
        case "notifications/initialized", "notifications/cancelled": return .null
        case "tools/list": return result(id: id, .object(["tools": .array(AgentTool.catalog.filter { $0.name == "storagedaddy_status" || permissions.contains($0.permission) }.map(\.json))]))
        case "tools/call":
            guard let name = request["params"]["name"].string else { return error(id: id, message: "Tool name is required.") }
            // The app rechecks authorization for every call, including unknown or
            // hidden tools, so denied attempts enter the native security audit.
            do { return result(id: id, toolResult(try await call(name, request["params"]["arguments"].object == nil ? .object([:]) : request["params"]["arguments"]))) }
            catch { return result(id: id, toolResult(.object(["error": .string(error.localizedDescription)]), isError: true)) }
        case "resources/list":
            guard permissions.contains("read") else { return result(id: id, .object(["resources": .array([])])) }
            return result(id: id, .object(["resources": .array(["free-up-space", "investigate-growth"].map { .object(["uri": .string("skill://storagedaddy/" + $0), "name": .string($0), "mimeType": .string("text/plain")]) })]))
        case "resources/read":
            guard permissions.contains("read"), let uri = request["params"]["uri"].string, let text = skill(uri.replacingOccurrences(of: "skill://storagedaddy/", with: "")) else { return error(id: id, message: "Unknown or unavailable resource.") }
            return result(id: id, .object(["contents": .array([.object(["uri": .string(uri), "mimeType": .string("text/plain"), "text": .string(text)])])]))
        case "prompts/list":
            return result(id: id, .object(["prompts": .array(permissions.contains("read") ? ["free-up-space", "investigate-growth"].map { .object(["name": .string($0), "description": .string("StorageDaddy local " + $0 + " procedure")]) } : [])]))
        case "prompts/get":
            guard permissions.contains("read"), let name = request["params"]["name"].string, let text = skill(name) else { return error(id: id, message: "Unknown or unavailable prompt.") }
            return result(id: id, .object(["messages": .array([.object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string(text)])])])]))
        default: return error(id: id, code: -32601, message: "Method not found.")
        }
    }
    public static func skill(_ name: String) -> String? {
        switch name { case "free-up-space": AgentProcedures.cleanup; case "investigate-growth": AgentProcedures.growth; default: nil }
    }
}
