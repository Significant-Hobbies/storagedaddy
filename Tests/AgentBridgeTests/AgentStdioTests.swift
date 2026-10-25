import XCTest
import Foundation
@testable import AgentBridge

private final class PairingFixture: @unchecked Sendable {
    let lock = NSLock()
    var approved = false
    var requestedHash: String?
    var calls = 0
    func handle(_ request: AgentBridgeRequest) async -> AgentJSON {
        switch request.operation {
        case "pair":
            return lock.withLock { requestedHash = request.payload["tokenHash"].string; return .object(["state": .string(approved ? "approved" : "pending")]) }
        case "session":
            return lock.withLock {
                guard approved, let token = request.token, AgentSecurity.hash(token) == requestedHash else { return .object(["state": .string("unauthorized")]) }
                return .object(["state": .string("approved"), "permissions": .array([.string("read")])])
            }
        case "rpc":
            guard lock.withLock({ approved && request.token.map(AgentSecurity.hash) == requestedHash }) else { return .object(["state": .string("unauthorized")]) }
            return await AgentMCP.respond(request.payload, permissions: ["read"]) { [self] _, _ in
                lock.withLock { calls += 1 }
                return .object(["fixture": .string("approved native bridge")])
            }
        default: return .null
        }
    }
}

private final class HelperOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
    var replies: [AgentJSON] {
        lock.withLock { bytes.split(separator: 10).compactMap { try? JSONDecoder().decode(AgentJSON.self, from: Data($0)) } }
    }
    func waitFor(_ condition: @escaping @Sendable ([AgentJSON]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if condition(replies) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(replies)
    }
}

final class AgentStdioTests: XCTestCase {
    func testRealHelperHandshakePairApprovalToolsAndCall() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [package.appendingPathComponent(".build/out/Products/Debug/storagedaddy-mcp"), package.appendingPathComponent(".build/debug/storagedaddy-mcp")]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return XCTFail("Build the stdio helper before this integration test.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sd-stdio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = PairingFixture(), server = AgentSocketServer(), path = directory.appendingPathComponent("s").path
        try server.start(path: path) { request in await state.handle(request) }
        defer { server.stop() }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = binary; process.arguments = ["--ephemeral", "--socket", path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let terminated = expectation(description: "helper exits when its client disconnects")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let captured = HelperOutputCapture(), reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return }
                captured.append(chunk)
            }
        }
        func send(_ id: Int, _ method: String, _ params: AgentJSON = .object([:])) throws {
            var data = try JSONEncoder().encode(AgentJSON.object(["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(method), "params": params])); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(1, "initialize", .object(["protocolVersion": .string("2025-06-18"), "clientInfo": .object(["name": .string("Fixture client"), "version": .string("1")])]))
        try send(2, "tools/list")
        let initialList = await captured.waitFor { replies in replies.contains { $0["id"].int == 2 } }
        XCTAssertTrue(initialList)
        let pairingDeadline = Date().addingTimeInterval(8)
        while state.lock.withLock({ state.requestedHash == nil }) && Date() < pairingDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(state.lock.withLock { state.requestedHash })
        state.lock.withLock { state.approved = true }
        let changed = await captured.waitFor { replies in replies.contains { $0["method"].string == "notifications/tools/list_changed" } }
        XCTAssertTrue(changed)
        try send(3, "tools/list")
        try send(4, "tools/call", .object(["name": .string("storagedaddy_status"), "arguments": .object([:])]))
        try input.fileHandleForWriting.close()
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertEqual(reader.wait(timeout: .now() + 2), .success)
        let replies = captured.replies
        XCTAssertEqual(replies.first(where: { $0["id"].int == 1 })?["result"]["serverInfo"]["name"].string, "storagedaddy")
        XCTAssertEqual(replies.first(where: { $0["id"].int == 2 })?["result"]["tools"].array?.count, 1)
        XCTAssertTrue((replies.first(where: { $0["id"].int == 3 })?["result"]["tools"].array?.count ?? 0) > 1)
        XCTAssertTrue(replies.contains(where: { $0["method"].string == "notifications/tools/list_changed" }))
        XCTAssertEqual(replies.first(where: { $0["id"].int == 4 })?["result"]["isError"].bool, false)
        XCTAssertEqual(state.lock.withLock { state.calls }, 1)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
