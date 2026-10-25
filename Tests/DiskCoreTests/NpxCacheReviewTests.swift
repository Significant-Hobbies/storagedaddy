import Foundation
import XCTest
@testable import DiskCore

final class NpxCacheReviewTests: XCTestCase {
    func testRetainsLoadedToolsEvenWithoutOpenScriptFiles() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try package(root: root, name: "abc", dependency: "some-package", bin: "fixture-cli")
        XCTAssertEqual(try NpxCacheReview.packageSummary(entry: entry), "some-package 1.0.0")
        for command in ["123 node " + entry.path + "/node_modules/some-package/start.js",
                        "123 fixture-cli", "123 npm exec fixture-cli@1.2.3",
                        "123 /usr/local/bin/fixture-cli --serve"] {
            XCTAssertThrowsError(try NpxCacheReview.validate(entries: [entry], processOutput: command))
        }
        XCTAssertNoThrow(try NpxCacheReview.validate(entries: [entry], processOutput: "123 fixture-cli-other\n456 node unrelated.js"))
        XCTAssertThrowsError(try NpxCacheReview.validate(entries: [entry], processOutput: ""))
        // A different cached version with the same CLI is conservatively kept.
        let other = try package(root: root, name: "def", dependency: "some-package", bin: "fixture-cli")
        XCTAssertThrowsError(try NpxCacheReview.validate(entries: [other], processOutput: "123 fixture-cli"))
    }

    func testParentAndDescendantSelectionsCannotBypassEntryChecks() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try package(root: root, name: "abc", dependency: "@scope/tool", bin: "fixture-cli")
        let cache = root.appendingPathComponent(".npm/_npx")
        for selection in [root.appendingPathComponent(".npm"), cache, entry, entry.appendingPathComponent("node_modules")] {
            XCTAssertEqual(try NpxCacheReview.affectedEntries(urls: [selection], home: root.path).map { $0.resolvingSymlinksInPath().path },
                           [entry.resolvingSymlinksInPath().path])
        }
        let scan = try await DiskScanner.scan(root: root)
        XCTAssertEqual(NpxCacheReview.entries(in: scan, home: root.path).map(\.name), ["abc"])
        XCTAssertTrue(NpxCacheReview.entries(in: scan, home: "/Users/someone-else").isEmpty)
        XCTAssertTrue(try NpxCacheReview.affectedEntries(urls: [root.appendingPathComponent("project")], home: root.path).isEmpty)
    }

    func testMalformedMissingAndSymlinkMetadataBlockCleanup() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try package(root: root, name: "abc", dependency: "some-package", bin: "fixture-cli")
        let manifest = entry.appendingPathComponent("package.json")
        try Data("{broken".utf8).write(to: manifest)
        XCTAssertThrowsError(try NpxCacheReview.validate(entries: [entry], processOutput: "123 unrelated"))
        try Data(#"{"dependencies":{"../../outside":"1"}}"#.utf8).write(to: manifest)
        XCTAssertThrowsError(try NpxCacheReview.commandNames(entry: entry))
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: entry.appendingPathComponent("node_modules/some-package/package.json"))
        XCTAssertThrowsError(try NpxCacheReview.commandNames(entry: entry))
    }

    func testCurrentProcessCLIBlocksOtherwiseUnopenedEntry() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try package(root: root, name: "abc", dependency: "some-package", bin: "swift-test")
        let scan = try await DiskScanner.scan(root: root)
        let id = try XCTUnwrap(scan.nodes.first { scan.url(for: $0.id).path == entry.path }?.id)
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan, home: root.path)
            XCTFail("The running test runner's CLI must protect the cache")
        } catch let error as NSError { XCTAssertEqual(error.domain, "NpxCacheReview") }
    }

    private func fixtureRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("npx-review-" + UUID().uuidString).resolvingSymlinksInPath()
    }
    private func package(root: URL, name: String, dependency: String, bin: String) throws -> URL {
        let entry = root.appendingPathComponent(".npm/_npx/" + name)
        let installed = entry.appendingPathComponent("node_modules/" + dependency)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["dependencies": [dependency: "1.0.0"]]).write(to: entry.appendingPathComponent("package.json"))
        try JSONSerialization.data(withJSONObject: ["version": "1.0.0", "bin": [bin: "start.js"]]).write(to: installed.appendingPathComponent("package.json"))
        return entry
    }
}
