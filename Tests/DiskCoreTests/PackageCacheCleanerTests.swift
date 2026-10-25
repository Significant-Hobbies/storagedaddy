import XCTest
@testable import DiskCore

final class PackageCacheCleanerTests: XCTestCase {
    func testExactNativeCommandsAndHomebrewClassification() async throws {
        XCTAssertEqual(PackageCacheTool.allCases.map(\.command), ["yarn cache clean", "uv cache clean", "npm cache clean --force", "brew cleanup -s", "pip3 cache purge"])
        XCTAssertTrue(CleanupGuidance.isSuggestedCache(category: .packageCaches, path: "/Users/fixture/Library/Caches/Homebrew", home: "/Users/fixture"))
        XCTAssertFalse(CleanupGuidance.canDeletePermanently(path: "/Users/fixture/Library/Caches/Homebrew", home: "/Users/fixture"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Library/Caches/Homebrew/downloads")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cache.appendingPathComponent("bottle.tar.gz"))
        let scan = try await DiskScanner.scan(root: root)
        let group = try XCTUnwrap(DeveloperInsights.analyze(scan).first { $0.category == .packageCaches })
        XCTAssertEqual(group.fileCount, 1)
        XCTAssertEqual(group.rootIDs.map { scan.nodes[$0].name }, ["Homebrew"])
    }

    func testCommandRunnerDrainsAndReportsNonzeroExitWithoutShellInterpretation() throws {
        let output = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "$(touch should-not-exist); literal"], directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.output, "$(touch should-not-exist); literal")
        let failure = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], directory: FileManager.default.temporaryDirectory)
        XCTAssertNotEqual(failure.status, 0)
    }
}
