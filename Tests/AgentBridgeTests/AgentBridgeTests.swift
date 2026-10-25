import XCTest
import Foundation
import Darwin
@testable import AgentBridge

final class AgentBridgeTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sd-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testPrivateSocketRoundTripAndStop() throws {
        let directory = try fixture(), path = directory.appendingPathComponent("s").path
        let server = AgentSocketServer()
        try server.start(path: path) { request in .object(["operation": .string(request.operation), "payload": request.payload]) }
        let response = try AgentSocketClient.request(.init(operation: "test", payload: .object(["value": .integer(42)])), path: path)
        XCTAssertEqual(response["operation"].string, "test")
        XCTAssertEqual(response["payload"]["value"].int, 42)
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let another = AgentSocketServer()
        XCTAssertThrowsError(try another.start(path: path) { _ in .null })
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try AgentSocketClient.request(.init(operation: "test"), path: path))
    }

    func testRefusesWorldReadableDirectoryAndSocketSymlink() throws {
        let directory = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try AgentSecurity.preparePrivateDirectory(directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("socket")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory.appendingPathComponent("nonexistent"))
        XCTAssertThrowsError(try AgentSocketServer().start(path: path.path) { _ in .null })
    }

    func testPolicyIsPrivateAndRejectsSymlinkOrOversize() throws {
        let directory = try fixture(), file = directory.appendingPathComponent("policy.json")
        try AgentSecurity.save(["value": "test"], to: file)
        XCTAssertEqual(try AgentSecurity.load([String: String].self, from: file), ["value": "test"])
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let link = directory.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AgentSecurity.load([String: String].self, from: link))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try AgentSecurity.load([String: String].self, from: file))
        XCTAssertThrowsError(try AgentSecurity.save(String(repeating: "x", count: 2 * 1024 * 1024 + 1), to: file))
    }

    func testRoleCatalogAndDeniedCallStillReachesPolicy() async {
        let request: AgentJSON = .object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("tools/list")])
        let read = await AgentMCP.respond(request, permissions: AgentRole.explorer.permissions) { _, _ in .null }
        let names = read["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
        XCTAssertTrue(names.contains("storagedaddy_search_files"))
        XCTAssertFalse(names.contains("storagedaddy_start_scan"))
        XCTAssertFalse(names.contains("storagedaddy_move_to_trash"))
        let pending = await AgentMCP.respond(request, permissions: []) { _, _ in .null }
        XCTAssertEqual(pending["result"]["tools"].array?.count, 1)
        let call: AgentJSON = .object(["jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/call"), "params": .object(["name": .string("storagedaddy_delete_permanently")])])
        let denied = await AgentMCP.respond(call, permissions: []) { _, _ in throw AgentSecurity.failure("Permission denied") }
        XCTAssertEqual(denied["result"]["isError"].bool, true)
    }

    func testNoDeletionExecutionToolAndBoundedRemovalSchema() {
        let removalTools = AgentTool.catalog.filter { $0.permission.hasPrefix("request_") }
        XCTAssertEqual(removalTools.count, 2)
        for tool in removalTools {
            XCTAssertEqual(tool.json["annotations"]["destructiveHint"].bool, false)
            XCTAssertEqual(tool.json["inputSchema"]["properties"]["nodeIDs"]["maxItems"].int, 20)
            XCTAssertTrue(tool.description.contains("NEVER"))
        }
        XCTAssertTrue(AgentRole.admin.permissions.isSuperset(of: AgentRole.operator.permissions))
    }

    func testTokenAndNumericInputValidation() throws {
        let first = try AgentSecurity.randomToken(), second = try AgentSecurity.randomToken()
        XCTAssertNotEqual(first, second); XCTAssertEqual(first.count, 43)
        XCTAssertTrue(AgentSecurity.validHash(AgentSecurity.hash(first)))
        XCTAssertFalse(AgentSecurity.validHash(String(repeating: "G", count: 64)))
        XCTAssertNil(AgentJSON.number(Double(Int.max)).int)
        XCTAssertNil(AgentJSON.number(1.5).int)
        XCTAssertEqual(AgentJSON.integer(1).int, 1)
    }
}
