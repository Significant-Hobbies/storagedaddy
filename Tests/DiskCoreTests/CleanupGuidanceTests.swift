import Foundation
import XCTest
@testable import DiskCore

final class CleanupGuidanceTests: XCTestCase {
    func testCorepackPackageManagerPayloadIsNeverSuggestedAsBuildOutput() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-corepack-\(UUID())")
        let relative = ".cache/node/corepack/v1/pnpm/10.33.2"
        let manager = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: manager.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manager.appendingPathComponent("package.json"))
        try Data([1]).write(to: manager.appendingPathComponent("dist/pnpm.cjs"))
        let scan = try await DiskScanner.scan(root: home)
        let node = try XCTUnwrap(scan.nodes.first { $0.name == "dist" })
        let path = scan.url(for: node.id).path
        XCTAssertTrue(CleanupGuidance.isInstalledRuntime(path: path))
        XCTAssertTrue(CleanupGuidance.isInstalledRuntime(path: "/System/Volumes/Data" + path))
        XCTAssertFalse(CleanupGuidance.isRegenerableFolder(path: path, home: home.path))
        let finding = DeveloperFinding(nodeID: node.id, category: .buildOutputs, allocatedBytes: node.allocatedBytes,
            projectID: nil, tool: "pnpm", evidence: "dist directory", consequence: "rebuild", confidence: "fixture", lastModified: Date())
        XCTAssertTrue(CleanupGuidance.quickCleanupIDs(in: scan, findings: [finding], home: home.path).isEmpty)
    }

    func testQuickCleanupIncludesRecentRebuildableFoldersAndKeepsAppComponents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-guidance-\(UUID().uuidString)")
        for path in ["project/package.json", "project/node_modules/module.js", ".cache/uv/cache", ".cache/huggingface/hub/weights", "Tool.app/Contents/Resources/package.json", "Tool.app/Contents/Resources/node_modules/module.js"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let scan = try await DiskScanner.scan(root: root)
        let directories: [(String, DeveloperCategory)] = [("project/node_modules", .nodeModules), (".cache/uv", .packageCaches), (".cache/huggingface", .modelCaches), ("Tool.app/Contents/Resources/node_modules", .nodeModules)]
        let findings = try directories.map { relative, category in
            let path = root.appendingPathComponent(relative).resolvingSymlinksInPath().path
            let node = try XCTUnwrap(scan.nodes.first { scan.url(for: $0.id).path == path })
            return DeveloperFinding(nodeID: node.id, category: category, allocatedBytes: node.allocatedBytes,
                projectID: nil, tool: "test", evidence: "fixture", consequence: "rebuild", confidence: "fixture", lastModified: Date())
        }
        let ids = CleanupGuidance.quickCleanupIDs(in: scan, findings: findings, home: root.path)
        let names = Set(ids.map { scan.nodes[$0].name })
        XCTAssertEqual(names, ["node_modules", "uv", "hub"])
        XCTAssertEqual(ids.filter { scan.nodes[$0].name == "node_modules" }.count, 1)
    }

    func testRegenerableRulesSeparateDownloadedCachesFromInstalledRuntimes() {
        let home = "/Users/test"
        for path in [home + "/.cache/uv", home + "/.cache/huggingface/hub", "/System/Volumes/Data" + home + "/Library/Caches/pnpm", home + "/Library/Developer/XcodeBuildMCP/workspaces/test/DerivedData"] {
            XCTAssertTrue(CleanupGuidance.isRegenerableFolder(path: path, home: home), path)
        }
        for path in [home + "/.cache/huggingface", home + "/.cache/huggingface/token", "/Applications/OpenClaw.app/Contents/Resources/node_modules", home + "/Library/Application Support/Buzz/node-tools/lib/node_modules", "/usr/local/lib/node_modules"] {
            XCTAssertFalse(CleanupGuidance.isRegenerableFolder(path: path, home: home), path)
        }
    }

    func testOpenFileProbeRecognizesFirmlinkAliasesAndFolderBoundaries() {
        let output = "p123\0cPython\0n/System/Volumes/Data/Users/test/.cache/uv/archive-v0/module.so\0\n"
        XCTAssertEqual(CleanupActiveUse.user(of: "/Users/test/.cache/uv", in: output), "Python (PID 123)")
        XCTAssertNil(CleanupActiveUse.user(of: "/Users/test/.cache/uv-other", in: output))
        XCTAssertNil(CleanupActiveUse.user(of: "/Users/other/.cache/uv", in: output))
    }

    func testChromeCacheGuidanceOnlyAppliesToChromeCache() {
        XCTAssertNotNil(CleanupGuidance.chromeCacheNote(path: "/Users/test/Library/Caches/Google/Chrome", home: "/Users/test"))
        XCTAssertNotNil(CleanupGuidance.chromeCacheNote(path: "/Users/test/Library/Caches/Google/Chrome/Default/Cache", home: "/Users/test"))
        XCTAssertNil(CleanupGuidance.chromeCacheNote(path: "/Users/test/Library/Application Support/Google/Chrome", home: "/Users/test"))
        XCTAssertNil(CleanupGuidance.chromeCacheNote(path: "/Users/test/Library/Caches/Google/Chrome-headless", home: "/Users/test"))
    }

    func testBatchSuggestionsExcludeInstalledToolsAndAmbiguousStores() {
        XCTAssertTrue(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: "/Users/test/Library/Caches/uv", home: "/Users/test"))
        XCTAssertTrue(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: "/Users/test/.cache/pip", home: "/Users/test"))
        for path in ["/Users/test/copy/Library/Caches/pip", "/Users/other/Library/Caches/pip", "/Users/test/.local/share/uv", "/Users/test/.m2/repository", "/Users/test/.cargo/registry", "/Users/test/project/build", "/Users/test/Library/Caches/unknown"] {
            XCTAssertFalse(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: path, home: "/Users/test"), path)
        }
        XCTAssertFalse(CleanupGuidance.isSuggestedCache(category: .pythonEnvironments, path: "/Users/test/.cache/uv", home: "/Users/test"))
        XCTAssertFalse(CleanupGuidance.isSuggestedCache(category: .claudeSessions, path: "/Users/test/.cache/uv", home: "/Users/test"))
    }

    func testGuidanceDoesNotPromiseBuildsOrSessionsAreDisposable() {
        XCTAssertEqual(CleanupGuidance.label(for: .buildOutputs), "Regeneration unconfirmed")
        XCTAssertEqual(CleanupGuidance.label(for: .claudeSessions), "Not regenerable · archive first")
        XCTAssertEqual(CleanupGuidance.label(for: .containerStorage), "Regeneration unconfirmed")
        XCTAssertEqual(CleanupGuidance.label(for: nil), "Regeneration unconfirmed")
    }
}
