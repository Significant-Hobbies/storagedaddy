import Foundation
import XCTest
@testable import DiskCore

final class NpxPackageCleanupTests: XCTestCase {
    func testIdlePackagesCanBeCleanedWhileSkippedPeerStaysIntactInRecovery() async throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let npx = home.appendingPathComponent(".npm/_npx")
        let entry = npx.appendingPathComponent("abcdef0123456789")
        let modules = entry.appendingPathComponent("node_modules")
        let cli = modules.appendingPathComponent("fixture-unused-cli")
        let kept = modules.appendingPathComponent("peer")
        for folder in [cli, kept] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let sentinel = kept.appendingPathComponent("credentials.js")
        try Data("fixture sentinel".utf8).write(to: sentinel)
        try Data(#"{"dependencies":{"fixture-unused-cli":"1.0.0"}}"#.utf8).write(to: entry.appendingPathComponent("package.json"))
        for folder in [cli, kept] { try Data("{}".utf8).write(to: folder.appendingPathComponent("package.json")) }
        try Data(repeating: 42, count: 65536).write(to: cli.appendingPathComponent("file.js"))
        let integrity = "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()
        let packageIndex = ["node_modules/fixture-unused-cli": ["integrity": integrity], "node_modules/peer": ["integrity": integrity]]
        try JSONEncoder().encode(["packages": packageIndex]).write(to: modules.appendingPathComponent(".package-lock.json"))
        let initialInode = try fm.attributesOfItem(atPath: sentinel.path)[.systemFileNumber] as? NSNumber

        let plan = try await DeveloperCleanupPlan.prepare(root: npx, home: home.path, quickCleanup: true)
        let row = try XCTUnwrap(plan.items.first)
        XCTAssertNil(row.keptReason)
        XCTAssertEqual(row.verifiedPackages, 1)
        let recovery = try XCTUnwrap(row.recoveryPath)
        let result = await plan.clean(ids: [row.id], permanently: true)
        XCTAssertEqual(result.deleted, [row.id], String(describing: result.kept))
        let preserved = URL(fileURLWithPath: recovery).appendingPathComponent("node_modules/peer/credentials.js")
        XCTAssertTrue(fm.fileExists(atPath: preserved.path))
        XCTAssertEqual(try fm.attributesOfItem(atPath: preserved.path)[.systemFileNumber] as? NSNumber, initialInode)
        XCTAssertFalse(fm.fileExists(atPath: modules.path))
        XCTAssertFalse(fm.fileExists(atPath: URL(fileURLWithPath: recovery).appendingPathComponent("node_modules/fixture-unused-cli").path))
        XCTAssertTrue(fm.fileExists(atPath: entry.appendingPathComponent("package.json").path))
        let retry = await plan.clean(ids: [row.id], permanently: true)
        XCTAssertTrue(retry.deleted.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: preserved.path))
    }
}
