import Foundation
import XCTest
@testable import DiskCore

final class NpxPackageCleanupTests: XCTestCase {
    func testProjectPnpmRecoveryKeepsProtectedPackageAndRequiresMatchingInstallLock() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let project = home.appendingPathComponent("project")
        let store = project.appendingPathComponent("node_modules/.pnpm")
        let safe = store.appendingPathComponent("tool@1.0.0/node_modules/tool")
        let kept = store.appendingPathComponent("peer@1.0.0/node_modules/peer")
        for folder in [safe, kept] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("package.json"))
        }
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data(repeating: 1, count: 100_000).write(to: safe.appendingPathComponent("code.js"))
        try Data("test sentinel".utf8).write(to: kept.appendingPathComponent("credentials.js"))
        let digest = Data(repeating: 1, count: 64).base64EncodedString()
        let lock = Data("""
        lockfileVersion: '9.0'
        packages:
          tool@1.0.0:
            resolution: {integrity: sha512-\(digest)}
          peer@1.0.0:
            resolution: {integrity: sha512-\(digest)}
        """.utf8)
        try lock.write(to: project.appendingPathComponent("pnpm-lock.yaml"))
        try Data("different".utf8).write(to: store.appendingPathComponent("lock.yaml"))
        let unmatched = try await DeveloperCleanupPlan.prepare(root: project, home: home.path, quickCleanup: true)
        XCTAssertNotNil(try XCTUnwrap(unmatched.items.first).keptReason)
        try lock.write(to: store.appendingPathComponent("lock.yaml"))
        let plan = try await DeveloperCleanupPlan.prepare(root: project, home: home.path, quickCleanup: true)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertNil(item.keptReason)
        XCTAssertEqual(item.verifiedPackages, 1)
        let recovery = URL(fileURLWithPath: try XCTUnwrap(item.recoveryPath))
        let result = await plan.clean(ids: [item.id], permanently: true)
        XCTAssertEqual(result.deleted, [item.id], String(describing: result.kept))
        XCTAssertTrue(fm.fileExists(atPath: recovery.appendingPathComponent("node_modules/.pnpm/peer@1.0.0/node_modules/peer/credentials.js").path))
        XCTAssertFalse(fm.fileExists(atPath: recovery.appendingPathComponent("node_modules/.pnpm/tool@1.0.0/node_modules/tool").path))
        XCTAssertTrue(fm.fileExists(atPath: project.appendingPathComponent("pnpm-lock.yaml").path))
    }

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

        let earlier = try await DeveloperCleanupPlan.prepare(root: npx, home: home.path, quickCleanup: true)
        let earlierRow = try XCTUnwrap(earlier.items.first)
        let changed = cli.appendingPathComponent("credentials.js")
        try Data("late fixture".utf8).write(to: changed)
        let blocked = await earlier.clean(ids: [earlierRow.id], permanently: true)
        XCTAssertTrue(blocked.deleted.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: changed.path))
        try fm.removeItem(at: changed)

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
