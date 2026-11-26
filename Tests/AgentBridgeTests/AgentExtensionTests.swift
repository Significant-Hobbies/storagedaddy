import XCTest
import Foundation
@testable import AgentBridge

final class AgentExtensionTests: XCTestCase {
    func testExtensionContainsManifestAndExecutableWithoutChangingClientConfiguration() throws {
        try verifyExtension(socket: nil)
    }

    func testEmbeddedExtensionUsesItsOwnNameAndSocket() throws {
        try verifyExtension(socket: "/private/tmp/daddyrad-test/agent.sock")
    }

    private func verifyExtension(socket: String?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sd-mcpb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try AgentExtensionBuilder.build(helper: URL(fileURLWithPath: "/usr/bin/true"), directory: directory, socket: socket)
        XCTAssertEqual(bundle.pathExtension, "mcpb")
        let extracted = directory.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", bundle.path, extracted.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let manifest = try JSONDecoder().decode(AgentJSON.self, from: Data(contentsOf: extracted.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest["manifest_version"].string, "0.2")
        XCTAssertEqual(manifest["server"]["type"].string, "binary")
        XCTAssertEqual(manifest["server"]["mcp_config"]["command"].string, "${__dirname}/server/storagedaddy-mcp")
        XCTAssertEqual(manifest["server"]["mcp_config"]["args"].array, socket.map { [.string("--socket"), .string($0)] } ?? [])
        XCTAssertEqual(manifest["name"].string, socket == nil ? "storagedaddy" : "daddyrad-storage")
        XCTAssertEqual(manifest["compatibility"]["platforms"].array, [.string("darwin")])
        XCTAssertEqual(manifest["tools_generated"].bool, true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: extracted.appendingPathComponent("server/storagedaddy-mcp").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: extracted.path)), ["manifest.json", "server"])
    }
}
