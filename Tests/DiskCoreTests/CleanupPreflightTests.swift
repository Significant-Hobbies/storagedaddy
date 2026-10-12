import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class CleanupPreflightTests: XCTestCase {
    func testRegenerableCacheAcceptsNormalWritesWithoutWeakeningExactReview() async throws {
        let fixture = try PreflightFixture()
        try fixture.write(".cache/uv/archive-v0/pkg/__pycache__/one.pyc", bytes: [1])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID(".cache/uv", in: scan)
        try fixture.write(".cache/uv/archive-v0/pkg/__pycache__/one.pyc", bytes: [2, 3])
        try fixture.write(".cache/uv/new-cache-entry", bytes: [4])
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan)
            XCTFail("Exact review must still reject a changed subtree")
        } catch { }
        try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id], home: fixture.root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".cache/uv/new-cache-entry").path))

        let cache = fixture.root.appendingPathComponent(".cache/uv")
        try FileManager.default.moveItem(at: cache, to: fixture.root.appendingPathComponent("held-uv"))
        try fixture.write(".cache/uv/replacement", bytes: [5])
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id], home: fixture.root.path)
            XCTFail("Replacing the cache root must still be rejected")
        } catch { }
    }

    func testRegenerableRequestCannotBypassPersonalDataChanges() async throws {
        let fixture = try PreflightFixture()
        try fixture.write("folder/original.txt", bytes: [1])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID("folder", in: scan)
        try fixture.write("folder/original.txt", bytes: [2, 3])
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id], home: fixture.root.path)
            XCTFail("A requested mode cannot turn personal data into a cache")
        } catch { }
    }

    func testRegenerableCacheStillRequiresApprovalForExcludedContents() async throws {
        let fixture = try PreflightFixture()
        try fixture.write(".cache/uv/item", bytes: [1])
        try fixture.write(".cache/uv/.env.example", bytes: [2])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID(".cache/uv", in: scan)
        let review: CleanupIncompleteReview
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id], home: fixture.root.path)
            return XCTFail("Excluded contents still require a reviewed warning")
        } catch let CleanupPreflightError.incompleteRescan(_, value) { review = value }
        try await CleanupPreflight.validate(ids: [id], in: scan, acknowledgedIncomplete: [id: review], regenerableIDs: [id], home: fixture.root.path)
    }

    func testRegenerableCacheRejectsOpenFiles() async throws {
        let fixture = try PreflightFixture()
        try fixture.write(".cache/uv/item", bytes: [1])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID(".cache/uv", in: scan)
        let handle = try FileHandle(forReadingFrom: fixture.root.appendingPathComponent(".cache/uv/item"))
        defer { try? handle.close() }
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id], home: fixture.root.path)
            XCTFail("Open cache files must be kept")
        } catch let error as NSError { XCTAssertEqual(error.domain, "CleanupActiveUse") }
    }

    func testInstalledAppDependencyCannotBeStagedAsStandaloneCleanup() async throws {
        let fixture = try PreflightFixture()
        try fixture.write("Tool.app/Contents/Resources/node_modules/runtime.js", bytes: [1])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID("Tool.app/Contents/Resources/node_modules", in: scan)
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id], home: fixture.root.path)
            XCTFail("Installed application components must stay protected")
        } catch let DiskAnalysisError.unsafePath(_, reason) { XCTAssertTrue(reason.contains("installed app component")) }
    }

    func testAllowsVerifiedFileAndFolderWhenUnrelatedEntriesWereSkipped() async throws {
        let fixture = try PreflightFixture()
        try fixture.write("folder/item.txt", bytes: [1])
        try fixture.write("elsewhere/.env.test", bytes: [2])
        let scan = try await fixture.scan()
        XCTAssertGreaterThan(scan.skipped, 0)
        try await CleanupPreflight.validate(ids: [fixture.nodeID("folder/item.txt", in: scan)], in: scan)
        try await CleanupPreflight.validate(ids: [fixture.nodeID("folder", in: scan)], in: scan)
    }

    func testRejectsFolderWithPreviouslySkippedSensitiveContents() async throws {
        let fixture = try PreflightFixture()
        try fixture.write("folder/item.txt", bytes: [1])
        try fixture.write("folder/.env.test", bytes: [2])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID("folder", in: scan)
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan)
            XCTFail("a folder with excluded contents must remain blocked")
        } catch let error as CleanupPreflightError {
            guard case .incompleteRescan = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testRejectsNestedMutationAfterOriginalScan() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/nested/item.txt", bytes: Array(repeating: 1, count: 8))
        let scan = try await fixture.scan()
        let folderID = try fixture.nodeID("folder", in: scan)

        try fixture.write("folder/nested/item.txt", bytes: Array(repeating: 2, count: 64))
        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan)
            XCTFail("expected the changed subtree to be rejected")
        } catch is CleanupPreflightError {
            // Expected.
        }
    }

    func testRejectsSensitiveDescendantDiscoveredDuringRescan() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/visible.txt", bytes: [1, 2, 3])
        let scan = try await fixture.scan()
        let folderID = try fixture.nodeID("folder", in: scan)

        try fixture.write("folder/nested/.env.production", bytes: Array(repeating: 9, count: 12))
        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan)
            XCTFail("expected a newly hidden sensitive descendant to be rejected")
        } catch let error as CleanupPreflightError {
            guard case .changedRecord = error else {
                return XCTFail("expected changed known directory metadata, got \(error.localizedDescription)")
            }
        }
    }

    func testAllowsExactReviewedIncompleteEvidence() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/visible.txt", bytes: [1, 2, 3])
        try fixture.write("folder/.env.example", bytes: [4])
        let scan = try await fixture.scan()
        let folderID = try fixture.nodeID("folder", in: scan)

        let review: CleanupIncompleteReview
        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan)
            XCTFail("expected review")
            return
        } catch let error as CleanupPreflightError {
            guard case let .incompleteRescan(_, value) = error else { return XCTFail("wrong error") }
            review = value
        }
        try await CleanupPreflight.validate(ids: [folderID], in: scan, acknowledgedIncomplete: [folderID: review])
    }

    func testRejectsMismatchedIncompleteReview() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/visible.txt", bytes: [1])
        try fixture.write("folder/.env.example", bytes: [2])
        let scan = try await fixture.scan()
        let folderID = try fixture.nodeID("folder", in: scan)
        let review: CleanupIncompleteReview
        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan)
            XCTFail("expected review")
            return
        } catch let error as CleanupPreflightError {
            guard case let .incompleteRescan(_, value) = error else { return XCTFail("wrong error") }
            review = value
        }
        let changed = CleanupIncompleteReview(skipped: review.skipped, details: review.details + ["another/.env: excluded by sensitive path policy"])
        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan, acknowledgedIncomplete: [folderID: changed])
            XCTFail("expected mismatched review to remain blocked")
        } catch let error as CleanupPreflightError {
            guard case .incompleteRescan = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testKnownMutationCannotBeOverriddenByIncompleteReview() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/visible.txt", bytes: [1])
        try fixture.write("folder/.env.example", bytes: [2])
        let scan = try await fixture.scan()
        let folderID = try fixture.nodeID("folder", in: scan)
        try fixture.write("folder/visible.txt", bytes: [3, 4])
        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan, acknowledgedIncomplete: [folderID: CleanupIncompleteReview(skipped: 1, details: [".env.example: excluded by sensitive path policy"])])
            XCTFail("expected known file mutation to win over incomplete override")
        } catch let error as CleanupPreflightError {
            guard case .changedRecord = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testRejectsSymlinkCandidate() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        XCTAssertEqual(symlink("folder", fixture.root.appendingPathComponent("link").path), 0)
        let scan = try await fixture.scan()
        let linkID = try fixture.nodeID("link", in: scan)
        do {
            try await CleanupPreflight.validate(ids: [linkID], in: scan)
            XCTFail("expected symlink guard")
        } catch is CleanupPreflightError { }
        catch { }
    }

    func testMountBoundaryAndTruncatedEvidenceCannotBeAcknowledged() {
        let root = URL(fileURLWithPath: "/fixture")
        XCTAssertFalse(CleanupIncompleteReview(skipped: 1, evidence: [.init(path: "/fixture/volume", reason: "mount boundary (protected volume)")], truncated: false, root: root).canAcknowledge)
        XCTAssertFalse(CleanupIncompleteReview(skipped: 1, evidence: [.init(path: "/fixture/hidden", reason: "unreadable directory")], truncated: true, root: root).canAcknowledge)
    }

    func testAcknowledgementCannotFollowChangedSkipListOrAnotherFolder() async throws {
        let fixture = try PreflightFixture()
        try fixture.write("folder/credentials.example", bytes: [1])
        try fixture.write("other/credentials.example", bytes: [1])
        let scan = try await fixture.scan()
        let id = try fixture.nodeID("folder", in: scan)
        let review: CleanupIncompleteReview
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan)
            return XCTFail("expected incomplete review")
        } catch let CleanupPreflightError.incompleteRescan(_, value) { review = value }
        let other = try fixture.nodeID("other", in: scan)
        do {
            try await CleanupPreflight.validate(ids: [other], in: scan, acknowledgedIncomplete: [other: review])
            XCTFail("another folder must require its own acknowledgement")
        } catch let CleanupPreflightError.incompleteRescan(_, value) { XCTAssertNotEqual(value, review) }

        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("folder/credentials.example"), to: fixture.root.appendingPathComponent("folder/secrets.example"))
        let refreshed = try await fixture.scan()
        let refreshedID = try fixture.nodeID("folder", in: refreshed)
        do {
            try await CleanupPreflight.validate(ids: [refreshedID], in: refreshed, acknowledgedIncomplete: [refreshedID: review])
            XCTFail("same count with different skipped paths must not reuse acknowledgement")
        } catch let CleanupPreflightError.incompleteRescan(_, value) {
            XCTAssertEqual(value.skipped, review.skipped)
            XCTAssertNotEqual(value, review)
        }
    }

    func testEvidenceIsBoundedAndLegacySnapshotsDecode() async throws {
        let fixture = try PreflightFixture()
        for n in 0..<513 { try fixture.write("folder/credentials.\(n)", bytes: []) }
        let scan = try await fixture.scan()
        XCTAssertEqual(scan.skipped, 513)
        XCTAssertEqual(scan.incompleteEvidence?.count, 512)
        XCTAssertEqual(scan.incompleteEvidenceTruncated, true)
        let id = try fixture.nodeID("folder", in: scan)
        do {
            try await CleanupPreflight.validate(ids: [id], in: scan)
            XCTFail("truncated evidence must block override")
        } catch let CleanupPreflightError.incompleteRescan(_, review) { XCTAssertFalse(review.canAcknowledge) }
        let data = try JSONEncoder().encode(scan)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "incompleteEvidence")
        legacy.removeValue(forKey: "incompleteEvidenceTruncated")
        legacy.removeValue(forKey: "processDiskReadBytes")
        let decoded = try JSONDecoder().decode(ScanResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.nodes.count, scan.nodes.count)
        XCTAssertNil(decoded.incompleteEvidence)
        XCTAssertNil(decoded.processDiskReadBytes)
    }

    func testAllowsAnUnchangedSubtree() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/nested/item.txt", bytes: [4, 5, 6, 7])
        let scan = try await fixture.scan()
        let folderID = try fixture.nodeID("folder", in: scan)

        do {
            try await CleanupPreflight.validate(ids: [folderID], in: scan)
        } catch {
            XCTFail("expected unchanged subtree to validate: \(error.localizedDescription)")
        }
    }

    func testHardLinkAccountingOutsideSubtreeDoesNotLookLikeMutation() async throws {
        let fixture = try PreflightFixture()
        try fixture.write("charged-outside.bin", bytes: Array(repeating: 1, count: 4096))
        try FileManager.default.linkItem(at: fixture.root.appendingPathComponent("charged-outside.bin"), to: fixture.root.appendingPathComponent("folder/nested/linked.bin"))
        let scan = try await fixture.scan()
        let id = try fixture.nodeID("folder", in: scan)
        let alone = try await DiskScanner.scan(root: scan.url(for: id), backend: .foundation)
        XCTAssertNotEqual(scan.nodes[id].allocatedBytes, alone.nodes[0].allocatedBytes)
        try await CleanupPreflight.validate(ids: [id], in: scan)
    }

    func testRejectsInvalidRootAndOverlappingCandidates() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.remove() }
        try fixture.write("folder/nested/item.txt", bytes: [8])
        let scan = try await fixture.scan()
        let rootID = try XCTUnwrap(scan.nodes.first(where: { $0.parent == nil })?.id)
        let folderID = try fixture.nodeID("folder", in: scan)
        let nestedID = try fixture.nodeID("folder/nested", in: scan)

        do {
            try await CleanupPreflight.validate(ids: [rootID], in: scan)
            XCTFail("expected the scan root to be rejected")
        } catch is CleanupPreflightError {
            // Expected.
        }
        do {
            try await CleanupPreflight.validate(ids: [folderID, nestedID], in: scan)
            XCTFail("expected overlapping candidates to be rejected")
        } catch is CleanupPreflightError {
            // Expected.
        }
    }
}

private final class PreflightFixture {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("DiskBuddyCleanupPreflight-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("folder/nested"), withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, bytes: [UInt8]) throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    func scan() async throws -> ScanResult {
        try await DiskScanner.scan(root: root, backend: .foundation)
    }

    func nodeID(_ relativePath: String, in scan: ScanResult) throws -> Int {
        let expected = root.appendingPathComponent(relativePath).standardizedFileURL.path
        return try XCTUnwrap(scan.nodes.first { scan.url(for: $0.id).standardizedFileURL.path == expected }?.id)
    }

    func remove() {
        // Keep fixture files for inspection; no deletion during this task.
    }
}
