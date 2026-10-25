import XCTest
@testable import DiskCore

final class DeveloperInsightsTests: XCTestCase {
    func testDiagnosticLogsAndNamespacedBrowserCaches() {
        let scan = ScanResult(rootPath: "/Users/test/Library", nodes: [
            node(0, nil, "Library", true, children: [1, 4, 7]),
            node(1, 0, "Logs", true, children: [2]),
            node(2, 1, "DiagnosticReports", true, children: [3]),
            node(3, 2, "app.ips", false, allocated: 10),
            node(4, 0, "Caches", true, children: [5]),
            node(5, 4, "ms-playwright", true, children: [6]),
            node(6, 5, "browser", false, allocated: 20),
            node(7, 0, "ordinary", true, children: [8]),
            node(8, 7, "playwright", true, children: [9]),
            node(9, 8, "source", false, allocated: 30)
        ])
        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.temporary, in: groups).allocatedBytes, 10)
        XCTAssertEqual(group(.packageCaches, in: groups).allocatedBytes, 20)
    }

    func testInstalledModulesRequireSupportingMarkersAndScopedCaches() {
        let scan = ScanResult(rootPath: "/Users/test", nodes: [
            node(0, nil, "test", true, children: [1, 5, 8, 11, 16]),
            node(1, 0, "php", true, children: [2, 3]),
            node(2, 1, "composer.json", false),
            node(3, 1, "vendor", true, allocated: 40, children: [4]),
            node(4, 3, "library.php", false, allocated: 40),
            node(5, 0, "ordinary", true, children: [6]),
            node(6, 5, "vendor", true, allocated: 90, children: [7]),
            node(7, 6, "notes", false, allocated: 90),
            node(8, 0, ".bun", true, children: [9]),
            node(9, 8, "install", true, children: [10]),
            node(10, 9, "cache", true, allocated: 20, children: [15]),
            node(11, 0, "ios", true, children: [12, 13]),
            node(12, 11, "Podfile", false),
            node(13, 11, "Pods", true, allocated: 30, children: [14]),
            node(14, 13, "library", false, allocated: 30),
            node(15, 10, "package", false, allocated: 20),
            node(16, 0, "ruby", true, children: [17, 18]),
            node(17, 16, "Gemfile", false),
            node(18, 16, "vendor", true, children: [19]),
            node(19, 18, "bundle", true, allocated: 50, children: [20]),
            node(20, 19, "gem", false, allocated: 50)
        ])
        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.installedModules, in: groups).allocatedBytes, 120)
        XCTAssertEqual(Set(group(.installedModules, in: groups).rootIDs), [3, 13, 19])
        XCTAssertEqual(group(.packageCaches, in: groups).allocatedBytes, 20)
        XCTAssertEqual(groups.reduce(Int64.zero) { $0 + $1.allocatedBytes }, 140)
    }

    func testClassificationObservesCancellation() {
        let scan = ScanResult(rootPath: "/Users/test", nodes: [DiskNode(id: 0, parent: nil, name: "test", isDirectory: true)])
        XCTAssertThrowsError(try DeveloperInsights.analyze(scan, cancellationCheck: { throw CancellationError() }))
    }

    func testClassifiesGitMetadataAsItsOwnNonoverlappingCategory() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "project", true, children: [2, 5]),
            node(2, 1, ".git", true, allocated: 21, logical: 24, children: [3]),
            node(3, 2, "objects", true, allocated: 21, logical: 24, children: [4]),
            node(4, 3, "pack", false, allocated: 21, logical: 24),
            node(5, 1, "node_modules", true, allocated: 9, logical: 10, children: [6]),
            node(6, 5, "package.js", false, allocated: 9, logical: 10)
        ])

        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.gitRepositories, in: groups).allocatedBytes, 21)
        XCTAssertEqual(group(.gitRepositories, in: groups).logicalBytes, 24)
        XCTAssertEqual(group(.gitRepositories, in: groups).rootIDs, [2])
        XCTAssertEqual(group(.nodeModules, in: groups).allocatedBytes, 9)
        XCTAssertEqual(groups.reduce(Int64.zero) { $0 + $1.allocatedBytes }, 30)
    }

    func testClassifiesKnownTreesWithoutDoubleCountingNestedSubtrees() {
        let scan = ScanResult(rootPath: "/Users/ada", nodes: [
            node(0, nil, "ada", true, children: [1, 8, 13, 15, 17]),
            node(1, 0, ".claude", true, children: [2, 6]),
            node(2, 1, "projects", true, children: [3, 4]),
            node(3, 2, "conversation.jsonl", false, allocated: 10, logical: 20),
            node(4, 2, "node_modules", true, allocated: 5, logical: 5, children: [5]),
            node(5, 4, "package.json", false, allocated: 5, logical: 5),
            node(6, 1, "cache", true, allocated: 7, logical: 9, children: [7]),
            node(7, 6, "index", false, allocated: 7, logical: 9),
            node(8, 0, ".codex", true, children: [9, 11]),
            node(9, 8, "sessions", true, allocated: 11, logical: 12, children: [10]),
            node(10, 9, "run.jsonl", false, allocated: 11, logical: 12),
            node(11, 8, "archived_sessions", true, allocated: 13, logical: 14, children: [12]),
            node(12, 11, "old.jsonl", false, allocated: 13, logical: 14),
            node(13, 0, "DerivedData", true, allocated: 17, logical: 19, children: [14]),
            node(14, 13, "build.db", false, allocated: 17, logical: 19),
            node(15, 0, "tmp", true, allocated: 23, logical: 29, children: [16]),
            node(16, 15, "scratch", false, allocated: 23, logical: 29),
            node(17, 0, "node_modules", true, allocated: 31, logical: 37, children: [18]),
            node(18, 17, "index.js", false, allocated: 31, logical: 37)
        ])

        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(groups.map(\.category), DeveloperCategory.allCases)
        XCTAssertEqual(group(.claudeSessions, in: groups).allocatedBytes, 10)
        XCTAssertEqual(group(.claudeSessions, in: groups).rootIDs, [3])
        XCTAssertEqual(group(.codexSessions, in: groups).allocatedBytes, 24)
        XCTAssertEqual(group(.codexSessions, in: groups).rootIDs, [12, 10])
        XCTAssertEqual(group(.aiCaches, in: groups).logicalBytes, 9)
        XCTAssertEqual(group(.nodeModules, in: groups).allocatedBytes, 36)
        XCTAssertEqual(group(.nodeModules, in: groups).rootIDs, [17, 4])
        XCTAssertEqual(group(.nodeModules, in: groups).rootAllocatedBytes, [17: 31, 4: 5])
        XCTAssertEqual(group(.buildOutputs, in: groups).allocatedBytes, 17)
        XCTAssertEqual(group(.temporary, in: groups).allocatedBytes, 23)
        XCTAssertEqual(group(.temporary, in: groups).rootAllocatedBytes, [15: 23])
        XCTAssertEqual(groups.reduce(Int64.zero) { $0 + $1.allocatedBytes }, 117)
    }

    func testFirstRecognizedSubtreeOwnsNestedBuildAndTemporaryStorage() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "node_modules", true, allocated: 30, logical: 45, children: [2, 4, 6]),
            node(2, 1, "dist", true, allocated: 5, logical: 10, children: [3]),
            node(3, 2, "bundle.js", false, allocated: 5, logical: 10),
            node(4, 1, "tmp", true, allocated: 7, logical: 15, children: [5]),
            node(5, 4, "scratch", false, allocated: 7, logical: 15),
            node(6, 1, "index.js", false, allocated: 18, logical: 20)
        ])

        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.nodeModules, in: groups).allocatedBytes, 30)
        XCTAssertEqual(group(.nodeModules, in: groups).rootIDs, [1])
        XCTAssertEqual(group(.nodeModules, in: groups).rootAllocatedBytes, [1: 30])
        XCTAssertEqual(group(.buildOutputs, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.temporary, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.temporary, in: groups).rootIDs, [])
    }

    func testRecognizesSelectedSessionAndMacOSTemporaryRoots() {
        let sessions = ScanResult(rootPath: "/Users/ada/.codex/sessions", nodes: [
            node(0, nil, "sessions", true, allocated: 8, logical: 9, children: [1]),
            node(1, 0, "session.jsonl", false, allocated: 8, logical: 9)
        ])
        let sessionGroups = DeveloperInsights.analyze(sessions)
        XCTAssertEqual(sessionGroups.count, DeveloperCategory.allCases.count)
        XCTAssertEqual(group(.codexSessions, in: sessionGroups).allocatedBytes, 8)
        XCTAssertEqual(group(.codexSessions, in: sessionGroups).rootIDs, [1])
        XCTAssertEqual(group(.claudeSessions, in: sessionGroups).allocatedBytes, 0)

        let temporary = ScanResult(rootPath: "/private/var/folders/ab/cdef/T", nodes: [
            node(0, nil, "T", true, allocated: 15, logical: 22, children: [1, 2]),
            node(1, 0, "loose", false, allocated: 3, logical: 4),
            node(2, 0, "node_modules", true, allocated: 12, logical: 18, children: [3]),
            node(3, 2, "index.js", false, allocated: 12, logical: 18)
        ])
        let temporaryGroups = DeveloperInsights.analyze(temporary)
        XCTAssertEqual(group(.temporary, in: temporaryGroups).allocatedBytes, 3)
        XCTAssertEqual(group(.temporary, in: temporaryGroups).rootIDs, [0])
        XCTAssertEqual(group(.temporary, in: temporaryGroups).rootAllocatedBytes, [0: 3])
        XCTAssertEqual(group(.nodeModules, in: temporaryGroups).allocatedBytes, 12)
        XCTAssertEqual(group(.nodeModules, in: temporaryGroups).rootAllocatedBytes, [2: 12])
    }

    func testIgnoresTemporaryAncestorForASelectedProjectSubtree() {
        let scan = ScanResult(rootPath: "/tmp/project", nodes: [
            node(0, nil, "project", true, children: [1, 2]),
            node(1, 0, "unclassified", false, allocated: 3, logical: 3),
            node(2, 0, "node_modules", true, allocated: 5, logical: 6, children: [3]),
            node(3, 2, "index.js", false, allocated: 5, logical: 6)
        ])

        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.temporary, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.nodeModules, in: groups).allocatedBytes, 5)
    }

    func testOnlyRecognizesJSONLFilesInsideKnownSessionDirectories() {
        let scan = ScanResult(rootPath: "/Users/ada", nodes: [
            node(0, nil, "ada", true, children: [1, 4, 8]),
            node(1, 0, ".claude", true, children: [2, 3]),
            node(2, 1, "notes.jsonl", false, allocated: 11, logical: 11),
            node(3, 1, "projects", true, children: [7]),
            node(4, 0, ".codex", true, children: [5]),
            node(5, 4, "projects", true, children: [6]),
            node(6, 5, "sessions", true, children: [9]),
            node(7, 3, "valid.jsonl", false, allocated: 14, logical: 14),
            node(8, 0, "reports", true, children: [10]),
            node(9, 6, "nested.jsonl", false, allocated: 12, logical: 12),
            node(10, 8, "sessions.jsonl", false, allocated: 13, logical: 13)
        ])

        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.claudeSessions, in: groups).allocatedBytes, 14)
        XCTAssertEqual(group(.codexSessions, in: groups).allocatedBytes, 0)
    }

    func testClassifiesNamedLanguageCachesModelsAndContainerStorage() {
        let scan = ScanResult(rootPath: "/Users/ada", nodes: [
            node(0, nil, "ada", true, children: [1, 3, 8, 11, 14, 17, 20, 24, 29]),
            node(1, 0, ".venv", true, children: [2]),
            node(2, 1, "python", false, allocated: 20, logical: 24),
            node(3, 0, ".cache", true, children: [4, 6]),
            node(4, 3, "pip", true, children: [5]),
            node(5, 4, "wheel", false, allocated: 11, logical: 13),
            node(6, 3, "huggingface", true, children: [7]),
            node(7, 6, "model.bin", false, allocated: 13, logical: 18),
            node(8, 0, ".cargo", true, children: [9]),
            node(9, 8, "registry", true, children: [10]),
            node(10, 9, "crate", false, allocated: 17, logical: 21),
            node(11, 0, ".gradle", true, children: [12]),
            node(12, 11, "caches", true, children: [13]),
            node(13, 12, "module", false, allocated: 19, logical: 22),
            node(14, 0, ".m2", true, children: [15]),
            node(15, 14, "repository", true, children: [16]),
            node(16, 15, "artifact", false, allocated: 23, logical: 25),
            node(17, 0, ".nuget", true, children: [18]),
            node(18, 17, "packages", true, children: [19]),
            node(19, 18, "package", false, allocated: 29, logical: 31),
            node(20, 0, "com.docker.docker", true, children: [21]),
            node(21, 20, "Data", true, children: [22]),
            node(22, 21, "vms", true, children: [23]),
            node(23, 22, "Docker.raw", false, allocated: 31, logical: 40),
            node(24, 0, ".local", true, children: [25]),
            node(25, 24, "share", true, children: [26]),
            node(26, 25, "containers", true, children: [27]),
            node(27, 26, "storage", true, children: [28]),
            node(28, 27, "layer", false, allocated: 37, logical: 44),
            node(29, 0, ".ollama", true, children: [30]),
            node(30, 29, "models", true, children: [31]),
            node(31, 30, "blob", false, allocated: 41, logical: 51)
        ])

        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.pythonEnvironments, in: groups).allocatedBytes, 20)
        XCTAssertEqual(group(.packageCaches, in: groups).allocatedBytes, 99)
        XCTAssertEqual(group(.packageCaches, in: groups).rootIDs, [18, 15, 12, 9, 4])
        XCTAssertEqual(group(.modelCaches, in: groups).allocatedBytes, 54)
        XCTAssertEqual(group(.modelCaches, in: groups).rootIDs, [30, 6])
        XCTAssertEqual(group(.containerStorage, in: groups).allocatedBytes, 68)
        XCTAssertEqual(group(.containerStorage, in: groups).rootAllocatedBytes, [22: 31, 27: 37])
    }

    func testAvoidsGenericProjectFolderFalsePositivesAndRecognizesSelectedCacheRoot() {
        let scan = ScanResult(rootPath: "/workspace", nodes: [
            node(0, nil, "workspace", true, children: [1]),
            node(1, 0, "project", true, children: [2, 4, 7, 10]),
            node(2, 1, "venv-notes", true, children: [3]),
            node(3, 2, "readme", false, allocated: 10, logical: 10),
            node(4, 1, "cache", true, children: [5]),
            node(5, 4, "pip", true, children: [6]),
            node(6, 5, "wheel", false, allocated: 11, logical: 11),
            node(7, 1, "docker", true, children: [8]),
            node(8, 7, "vms", true, children: [9]),
            node(9, 8, "disk", false, allocated: 12, logical: 12),
            node(10, 1, "models", true, children: [11]),
            node(11, 10, "weights", false, allocated: 13, logical: 13)
        ])
        let groups = DeveloperInsights.analyze(scan)
        XCTAssertEqual(group(.pythonEnvironments, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.packageCaches, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.containerStorage, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.modelCaches, in: groups).allocatedBytes, 0)

        let selectedCache = ScanResult(rootPath: "/Users/ada/.cache/uv", nodes: [
            node(0, nil, "uv", true, children: [1]),
            node(1, 0, "archive", false, allocated: 8, logical: 9)
        ])
        let selectedGroups = DeveloperInsights.analyze(selectedCache)
        XCTAssertEqual(group(.packageCaches, in: selectedGroups).allocatedBytes, 8)
        XCTAssertEqual(group(.packageCaches, in: selectedGroups).rootAllocatedBytes, [0: 8])
    }

    func testInstallersMatchByExtensionAsPerFileRoots() {
        let scan = ScanResult(rootPath: "/Users/ada", nodes: [
            node(0, nil, "ada", true, children: [1, 3, 5, 7]),
            node(1, 0, "Downloads", true, children: [2]),
            node(2, 1, "Tool.dmg", false, allocated: 100, logical: 120),
            node(3, 0, "Library", true, children: [4]),
            node(4, 3, "agent.pkg", false, allocated: 40, logical: 44),
            node(5, 0, "archive.zip", false, allocated: 60, logical: 66),
            node(6, 0, "node_modules", true, allocated: 10, children: [7]),
            node(7, 6, "fixture.dmg", false, allocated: 10, logical: 10)
        ])
        let groups = DeveloperInsights.analyze(scan)
        let installers = group(.installers, in: groups)
        XCTAssertEqual(installers.allocatedBytes, 140)
        XCTAssertEqual(Set(installers.rootIDs), [2, 4])
        // A .dmg vendored inside node_modules stays with its owning subtree.
        XCTAssertEqual(group(.oldDownloads, in: groups).allocatedBytes, 0)
        XCTAssertEqual(group(.nodeModules, in: groups).allocatedBytes, 10)
    }

    func testOldDownloadsNeedTheFolderAgeAndSize() {
        let now = Date()
        let old = now.addingTimeInterval(-120 * 86400)
        let fresh = now.addingTimeInterval(-3 * 86400)
        let floor = DeveloperInsights.oldDownloadMinimumBytes
        let scan = ScanResult(rootPath: "/Users/ada", nodes: [
            node(0, nil, "ada", true, children: [1, 7, 9]),
            node(1, 0, "Downloads", true, children: [2, 3, 4, 5, 6]),
            node(2, 1, "big-old.bin", false, allocated: floor, logical: floor, modified: old),
            node(3, 1, "big-fresh.bin", false, allocated: floor, logical: floor, modified: fresh),
            node(4, 1, "small-old.bin", false, allocated: 5, logical: 5, modified: old),
            node(5, 1, "setup.dmg", false, allocated: floor, logical: floor, modified: old),
            node(6, 1, "deep", true, children: [10]),
            node(7, 0, "Documents", true, children: [8]),
            node(8, 7, "big-old.bin", false, allocated: floor, logical: floor, modified: old),
            node(9, 0, "node_modules", true, allocated: 30, children: [11]),
            node(10, 6, "nested-old.bin", false, allocated: floor, logical: floor, modified: old),
            node(11, 9, "stale.js", false, allocated: 30, logical: 30, modified: old)
        ])
        let groups = DeveloperInsights.analyze(scan, now: now, cancellationCheck: {})
        let downloads = group(.oldDownloads, in: groups)
        // Stale large files at any depth under Downloads; the .dmg is an
        // installer, the Documents copy and node_modules file are not downloads.
        XCTAssertEqual(downloads.allocatedBytes, floor * 2)
        XCTAssertEqual(Set(downloads.rootIDs), [2, 10])
        XCTAssertEqual(group(.installers, in: groups).allocatedBytes, floor)
        XCTAssertEqual(group(.nodeModules, in: groups).allocatedBytes, 30)
    }

    func testScanningDownloadsRootMarksEverythingInside() {
        let now = Date()
        let old = now.addingTimeInterval(-200 * 86400)
        let floor = DeveloperInsights.oldDownloadMinimumBytes
        let scan = ScanResult(rootPath: "/Users/ada/Downloads", nodes: [
            node(0, nil, "Downloads", true, children: [1]),
            node(1, 0, "old.bin", false, allocated: floor, logical: floor, modified: old)
        ])
        let groups = DeveloperInsights.analyze(scan, now: now, cancellationCheck: {})
        XCTAssertEqual(group(.oldDownloads, in: groups).allocatedBytes, floor)
        XCTAssertEqual(group(.oldDownloads, in: groups).rootIDs, [1])
    }

    private func group(_ category: DeveloperCategory, in groups: [DeveloperGroup]) -> DeveloperGroup {
        groups.first { $0.category == category }!
    }

    private func node(
        _ id: Int,
        _ parent: Int?,
        _ name: String,
        _ directory: Bool,
        allocated: Int64 = 0,
        logical: Int64 = 0,
        modified: Date = .distantPast,
        children: [Int] = []
    ) -> DiskNode {
        DiskNode(
            id: id,
            parent: parent,
            name: name,
            isDirectory: directory,
            logicalBytes: logical,
            allocatedBytes: allocated,
            modified: modified,
            children: children
        )
    }
}
