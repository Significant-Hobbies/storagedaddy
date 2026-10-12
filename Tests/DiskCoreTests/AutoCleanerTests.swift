import Foundation
import XCTest
@testable import DiskCore

final class AutoCleanerTests: XCTestCase {
    private let mb: Int64 = 1024 * 1024
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(TimeInterval(-days * 86_400))
    }

    private func finding(
        _ id: Int, _ category: DeveloperCategory, bytes: Int64, modified: Date,
    ) -> DeveloperFinding {
        DeveloperFinding(
            nodeID: id, category: category, allocatedBytes: bytes, projectID: nil,
            tool: "test", evidence: "", consequence: "", confidence: "name", lastModified: modified,
        )
    }

    private func scan() -> ScanResult {
        ScanResult(rootPath: "/Users/test", nodes: [
            DiskNode(id: 0, parent: nil, name: "test", isDirectory: true, children: [1, 2, 3, 4, 5]),
            DiskNode(id: 1, parent: 0, name: "old-build", isDirectory: true),
            DiskNode(id: 2, parent: 0, name: "node_modules", isDirectory: true),
            DiskNode(id: 3, parent: 0, name: "Library", isDirectory: true, children: [4]),
            DiskNode(id: 4, parent: 3, name: "Caches", isDirectory: true, children: [5]),
            DiskNode(id: 5, parent: 4, name: "npm", isDirectory: true),
        ])
    }

    func testSuggestsStaleBuildsModulesAndCaches() {
        let suggestions = AutoCleaner.suggestions(
            scan: scan(),
            findings: [
                finding(1, .buildOutputs, bytes: 200 * mb, modified: daysAgo(20)),
                finding(2, .nodeModules, bytes: 500 * mb, modified: daysAgo(45)),
                finding(5, .packageCaches, bytes: 100 * mb, modified: daysAgo(60)),
            ],
            now: now, home: "/Users/test",
        )
        XCTAssertEqual(suggestions.map(\.id), [2, 1, 5])
        XCTAssertEqual(suggestions[0].staleDays, 45)
        XCTAssertEqual(suggestions[2].path, "/Users/test/Library/Caches/npm")
    }

    func testFreshFoldersAndOtherCategoriesAreExcluded() {
        let suggestions = AutoCleaner.suggestions(
            scan: scan(),
            findings: [
                finding(1, .buildOutputs, bytes: 200 * mb, modified: daysAgo(5)),
                finding(2, .nodeModules, bytes: 500 * mb, modified: daysAgo(29)),
                finding(5, .gitRepositories, bytes: 2_000 * mb, modified: daysAgo(400)),
                finding(1, .claudeSessions, bytes: 100 * mb, modified: daysAgo(200)),
            ],
            now: now, home: "/Users/test",
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testTinyFoldersAreNotSuggested() {
        let suggestions = AutoCleaner.suggestions(
            scan: scan(),
            findings: [finding(1, .buildOutputs, bytes: 2 * mb, modified: daysAgo(90))],
            now: now, home: "/Users/test",
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testPackageCachesOutsideSystemStoresAreNotSuggested() {
        // A "cache" folder inside a project is never auto-suggested even when stale.
        let suggestions = AutoCleaner.suggestions(
            scan: scan(),
            findings: [finding(4, .packageCaches, bytes: 100 * mb, modified: daysAgo(90))],
            now: now, home: "/Users/test",
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testThresholdBoundaryIsInclusive() {
        let suggestions = AutoCleaner.suggestions(
            scan: scan(),
            findings: [
                finding(1, .buildOutputs, bytes: 100 * mb, modified: daysAgo(14)),
                finding(2, .nodeModules, bytes: 100 * mb, modified: daysAgo(30)),
            ],
            now: now, home: "/Users/test",
        )
        XCTAssertEqual(suggestions.count, 2)
    }

    func testFutureDatesAreNotSuggested() {
        let suggestions = AutoCleaner.suggestions(
            scan: scan(),
            findings: [finding(1, .buildOutputs, bytes: 100 * mb, modified: daysAgo(-5))],
            now: now, home: "/Users/test",
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testInstalledAppAndToolRuntimeDependenciesAreNeverSuggested() {
        for root in ["/Applications/OpenClaw.app/Contents/Resources", "/System/Volumes/Data/Applications/OpenClaw.app/Contents/Resources", "/Users/test/Library/Application Support/Buzz/node-tools/lib"] {
            let scan = ScanResult(rootPath: root, nodes: [
                DiskNode(id: 0, parent: nil, name: "Resources", isDirectory: true, children: [1]),
                DiskNode(id: 1, parent: 0, name: "node_modules", isDirectory: true)
            ])
            XCTAssertTrue(AutoCleaner.suggestions(scan: scan, findings: [finding(1, .nodeModules, bytes: 100 * mb, modified: daysAgo(90))], now: now, home: "/Users/test").isEmpty, root)
        }
    }
}
