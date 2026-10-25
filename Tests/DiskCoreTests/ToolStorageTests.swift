import Foundation
import XCTest
@testable import DiskCore

final class ToolStorageTests: XCTestCase {
    func testRunningOwnersAreKeptEvenWithClosedDataFiles() throws {
        for (path, command) in [
            ("Library/Application Support/Cursor/snapshots", "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            ("Library/Application Support/Claude/vm_bundles", "/Applications/Claude.app/Contents/MacOS/Claude"),
            ("Library/Developer/Xcode/iOS DeviceSupport", "/Applications/Xcode-27.app/Contents/MacOS/Xcode"),
            (".gortex/store", "/usr/local/bin/gortex"),
            (".selltraces/traces.db", "/usr/local/bin/selltraces")
        ] {
            let urls = [URL(fileURLWithPath: "/Users/fixture/" + path)]
            XCTAssertThrowsError(try ToolStorage.validateActiveUse(urls: urls, processOutput: "123 " + command))
            XCTAssertNoThrow(try ToolStorage.validateActiveUse(urls: urls, processOutput: "123 /usr/bin/unrelated"))
        }
        XCTAssertNoThrow(try ToolStorage.validateActiveUse(urls: [URL(fileURLWithPath: "/Users/fixture/Library/Application Support/Claude/vm_bundles")],
            processOutput: "123 /Users/fixture/.local/bin/claude"))
    }

    func testRecognizesDataFootprintsWithoutClaimingConfigurationOrDoubleCounting() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            "Library/Application Support/Cursor/snapshots/checkpoint.bin",
            "Library/Application Support/Claude/vm_bundles/runtime.bin",
            "Library/Developer/Xcode/iOS DeviceSupport/26.5/symbols.bin",
            ".gortex/store/index.sqlite", ".selltraces/traces.db",
            ".gortex/config.yaml", ".selltraces/config.json",
            ".selltraces/credentials.json", "project/store/original.txt",
            "Library/pnpm/store/v10/package.bin"
        ] { try write(path, root: root) }
        let scan = try await DiskScanner.scan(root: root)
        let groups = DeveloperInsights.analyze(scan)
        let data = try XCTUnwrap(groups.first { $0.category == .toolData })
        XCTAssertEqual(data.fileCount, 5)
        let report = DeveloperReport.build(scan: scan, groups: groups)
        XCTAssertEqual(Set(report.findings.filter { $0.category == .toolData }.map(\.tool)),
                       ["Cursor snapshots", "Claude VM bundles", "iOS DeviceSupport", "GorTex", "sellTraces"])
        XCTAssertTrue(report.findings.filter { $0.category == .toolData }.allSatisfy { !$0.consequence.isEmpty })
        let caches = try XCTUnwrap(groups.first { $0.category == .packageCaches })
        XCTAssertEqual(caches.fileCount, 1)
        XCTAssertEqual(report.findings.first { $0.category == .packageCaches }?.tool, "pnpm")
        XCTAssertTrue(CleanupGuidance.quickCleanupIDs(in: scan, findings: report.findings, home: root.path).isEmpty)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.fileCount }, 6)
    }

    func testSelectedNestedDataRootStillRetainsItsOwner() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ".gortex/store/nested"
        try write(path + "/state.bin", root: root)
        let scan = try await DiskScanner.scan(root: root.appendingPathComponent(path))
        let report = DeveloperReport.build(scan: scan, groups: DeveloperInsights.analyze(scan))
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings.first?.tool, "GorTex")
        XCTAssertEqual(report.findings.first?.category, .toolData)
    }

    func testToolRootsConfigurationAndContainingFoldersCannotBeRemoved() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("bundle/.selltraces/traces.db", root: root)
        try write("bundle/.selltraces/config.json", root: root)
        try write("bundle/.selltraces/credentials.json", root: root)
        try write(".gortex/store/index.sqlite", root: root)
        try write(".gortex/config.yaml", root: root)
        let scan = try await DiskScanner.scan(root: root)
        for path in ["bundle", "bundle/.selltraces", "bundle/.selltraces/config.json", ".gortex", ".gortex/config.yaml"] {
            let id = try nodeID(path, scan: scan, root: root)
            do {
                try await CleanupPreflight.validate(ids: [id], in: scan, home: root.path)
                XCTFail("Protected tool selection accepted: " + path)
            } catch let error as NSError { XCTAssertEqual(error.domain, "ToolStorage", path) }
        }
        XCTAssertNoThrow(try ToolStorage.validateCleanup(path: root.appendingPathComponent("bundle/.selltraces/traces.db").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle/.selltraces/credentials.json").path))
    }

    func testEveryReviewedToolAndOrdinaryFileRejectsOpenHandles() async throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = [
            ("Library/Application Support/Cursor/snapshots", "state.bin"),
            ("Library/Application Support/Claude/vm_bundles", "runtime.bin"),
            ("Library/Developer/Xcode/iOS DeviceSupport", "symbols.bin"),
            (".gortex/store", "index.sqlite"),
            (".selltraces", "traces.db"),
            ("ordinary", "original.txt")
        ]
        for (parent, file) in paths { try write(parent + "/" + file, root: root) }
        let scan = try await DiskScanner.scan(root: root)
        for (parent, file) in paths {
            let relative = parent == ".selltraces" ? parent + "/" + file : parent
            let id = try nodeID(relative, scan: scan, root: root)
            let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(parent + "/" + file))
            do {
                try await CleanupPreflight.validate(ids: [id], in: scan, home: root.path)
                XCTFail("Open data accepted: " + parent)
            } catch let error as NSError { XCTAssertEqual(error.domain, "CleanupActiveUse", parent) }
            try handle.close()
            // Owner-process matching is tested separately with a controlled
            // snapshot; a real Cursor/Xcode may be running on the test host.
            if parent == "ordinary" { try await CleanupPreflight.validate(ids: [id], in: scan, home: root.path) }
        }
    }

    private func fixtureRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tool-storage-" + UUID().uuidString).resolvingSymlinksInPath()
    }
    private func write(_ path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
    }
    private func nodeID(_ path: String, scan: ScanResult, root: URL) throws -> Int {
        try XCTUnwrap(scan.nodes.first { scan.url(for: $0.id).path == root.appendingPathComponent(path).path }?.id)
    }
}
