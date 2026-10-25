import XCTest
@testable import DiskCore

final class PackageCacheCleanerTests: XCTestCase {
    func testPnpmDiscoversTheStoreUsingTheManager() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pnpm")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$PWD/arguments\"\nprintf '%s\\n' \"$PWD/store\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let store = try PackageCacheTool.pnpm.cacheDirectory(executable: executable, home: root)
        XCTAssertEqual(store.lastPathComponent, "store")
        // $PWD is physical on macOS; compare parent identity across /var aliases.
        let actual = try FileManager.default.attributesOfItem(atPath: store.deletingLastPathComponent().path)[.systemFileNumber] as? NSNumber
        let expected = try FileManager.default.attributesOfItem(atPath: root.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(actual)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8), "store\npath\n")
    }

    func testExactNativeCommandsAndHomebrewClassification() async throws {
        XCTAssertEqual(PackageCacheTool.allCases.map(\.command), ["yarn cache clean", "uv cache clean", "npm cache clean --force", "brew cleanup -s", "pip3 cache purge", "pnpm store prune"])
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
        let evidence = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf stdout; printf warning >&2"], directory: FileManager.default.temporaryDirectory,
            requireCompleteOutput: true, mergeStandardError: false)
        XCTAssertEqual(evidence.output, "stdout")
        let failure = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], directory: FileManager.default.temporaryDirectory)
        XCTAssertNotEqual(failure.status, 0)
        XCTAssertThrowsError(try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%04096d", "1"], directory: FileManager.default.temporaryDirectory,
            maximumOutputBytes: 32, requireCompleteOutput: true))
    }
}
