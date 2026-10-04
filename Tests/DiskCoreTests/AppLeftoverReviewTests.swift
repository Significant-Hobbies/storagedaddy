import Foundation
import XCTest
@testable import DiskCore

final class AppLeftoverReviewTests: XCTestCase {
    private let library = URL(fileURLWithPath: "/fixture/Library")
    private let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var live: AppLeftoverInventory.Application {
        .init(bundleID: "com.acme.live", names: ["Live Editor.app", "Café Studio"])
    }
    private func inventory(_ completeness: AppLeftoverInventory.Completeness = .complete) -> AppLeftoverInventory {
        .init(applications: [live], completeness: completeness, checkedAt: checkedAt)
    }
    /// In-memory fixture only. No directories, bundles, plists, or body files are accessed.
    private func scan(_ entries: [(String, String)]) -> ScanResult {
        var nodes = [DiskNode(id: 0, parent: nil, name: "Library", isDirectory: true)]
        for (category, name) in entries {
            let parent: Int
            if let existing = nodes.first(where: { $0.parent == 0 && $0.name == category }) {
                parent = existing.id
            } else {
                parent = nodes.count
                nodes.append(DiskNode(id: parent, parent: 0, name: category, isDirectory: true))
                nodes[0].children.append(parent)
            }
            let id = nodes.count
            nodes.append(DiskNode(id: id, parent: parent, name: name, isDirectory: category != "Preferences" && category != "LaunchAgents", allocatedBytes: 4096))
            nodes[parent].children.append(id)
        }
        return ScanResult(rootPath: library.path, nodes: nodes, started: checkedAt)
    }
    private func analyze(_ scan: ScanResult, _ reference: AppLeftoverInventory? = nil) -> AppLeftoverReviewResult {
        AppLeftoverReview.analyze(scan: scan, inventory: reference ?? inventory(), libraryRoot: library)
    }

    func testLiveBundleSubidentifierAndFullNameVariantsAreProtected() {
        let names = ["com.acme.live", "com.acme.live.helper", "Live-Editor", "live_editor", "Cafe Studio"]
        let result = analyze(scan(names.map { ("Caches", $0) }))
        XCTAssertEqual(result.records.count, names.count)
        XCTAssertTrue(result.records.allSatisfy { $0.status == .protected })
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.records.allSatisfy { $0.evidence.contains { $0.contains("Installed reference") } })
    }

    func testInactiveIdentifierHasHonestAbsenceEvidenceAndUnknowns() {
        let result = analyze(scan([("Preferences", "org.example.retired.plist")]))
        let record = result.candidates.first
        XCTAssertEqual(result.inventoryCheckedAt, checkedAt)
        XCTAssertEqual(record?.path, "/fixture/Library/Preferences/org.example.retired.plist")
        XCTAssertEqual(record?.allocatedUpperBound, 4096)
        XCTAssertTrue(record?.reason.contains("safety remain unknown") == true)
        XCTAssertTrue(record?.evidence.contains { $0.contains("No exact bundle ID") } == true)
        XCTAssertFalse(record?.unknowns.isEmpty ?? true)
    }

    func testIncompleteUnknownEmptyUndatedAndMissingMetadataFailClosed() {
        let references = [inventory(.partial), inventory(.unknown),
            AppLeftoverInventory(applications: [], completeness: .complete, checkedAt: checkedAt),
            AppLeftoverInventory(applications: [live], completeness: .complete, checkedAt: nil),
            AppLeftoverInventory(applications: [.init(bundleID: nil, names: ["Live Editor"])], completeness: .complete, checkedAt: checkedAt)]
        for reference in references {
            let result = analyze(scan([("Caches", "org.example.retired"), ("Caches", "Live Editor")]), reference)
            XCTAssertFalse(result.absenceEvidenceAvailable)
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertEqual(result.records.first { $0.name == "org.example.retired" }?.status, .unidentified)
            XCTAssertEqual(result.records.first { $0.name == "Live Editor" }?.status,
                           reference.applications.isEmpty ? .unidentified : .protected)
        }
    }

    func testOSSharedVendorAndAmbiguousNamesAreNeverCandidates() {
        let names = ["com.apple.Safari", "com.google.retired", "com.acme.other", "group.org.example.app", "org.example.shared", "Shared", "Live", "com.acme.liveish", "org.example", "org..retired"]
        let result = analyze(scan(names.map { ("Application Support", $0) }))
        XCTAssertEqual(result.records.count, names.count)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.records.first { $0.name == "Live" }?.status, .unidentified)
    }

    func testOnlyEightDirectRootsAndNoSecretLookingNames() {
        let entries = AppLeftoverReview.categories.map { ($0, "org.example.retired" + ($0 == "Saved Application State" ? ".savedState" : "")) }
            + [("Logs", "org.example.retired"), ("Caches", "org.example.secret"),
               ("Preferences", "org.example.apikey.plist"), ("Caches", ".env"), ("Caches", "org.example.keychain")]
        var fixture = scan(entries)
        let parent = fixture.nodes.first { $0.name == "org.example.retired" && $0.isDirectory }!.id
        let id = fixture.nodes.count
        fixture.nodes.append(DiskNode(id: id, parent: parent, name: "org.example.nested", isDirectory: true, allocatedBytes: 9000))
        fixture.nodes[parent].children.append(id)
        let result = analyze(fixture)
        XCTAssertEqual(result.candidates.count, 8)
        XCTAssertFalse(result.records.contains { $0.name == "org.example.nested" })
        XCTAssertTrue(result.records.allSatisfy { $0.allocatedUpperBound == 4096 })
    }

    func testSymlinksMalformedAncestryAndWrongScopeAreExcluded() {
        var fixture = scan([("Caches", "org.example.retired")])
        fixture.nodes[1].isSymlink = true
        XCTAssertTrue(analyze(fixture).records.isEmpty)
        fixture.nodes[1].isSymlink = false
        fixture.nodes[2].isSymlink = true
        XCTAssertTrue(analyze(fixture).records.isEmpty)
        fixture.nodes[2].isSymlink = false
        fixture.nodes[2].parent = 2
        XCTAssertTrue(analyze(fixture).records.isEmpty)
        fixture = scan([("Caches", "../org.example.retired")])
        XCTAssertTrue(analyze(fixture).records.isEmpty)
        fixture = scan([("Caches", "org.example.retired")])
        fixture.rootPath = "/fixture/OtherLibrary"
        XCTAssertTrue(analyze(fixture).records.isEmpty)
    }

    func testSubscansAndPartialMeasurementRemainHonest() {
        let fixture = ScanResult(rootPath: "/fixture/Library/Caches", nodes: [
            DiskNode(id: 0, parent: nil, name: "Caches", isDirectory: true, children: [1]),
            DiskNode(id: 1, parent: 0, name: "org.example.retired", isDirectory: true, allocatedBytes: 4096)
        ], errors: ["Fixture access denied"], skipped: 1)
        let result = analyze(fixture)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertTrue(result.scanIncomplete)
        XCTAssertNil(result.candidates[0].allocatedUpperBound)
        XCTAssertTrue(result.candidates[0].unknowns.contains { $0.contains("Scan is incomplete") })
    }
}
