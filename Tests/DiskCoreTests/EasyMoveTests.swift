import Foundation
import Darwin
import XCTest
@testable import DiskCore

final class EasyMoveTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL, EasyMoveStore) {
        let temporary = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/"))
        let root = temporary.appendingPathComponent("easy-move-" + UUID().uuidString)
        let source = root.appendingPathComponent("source/report.txt")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("reviewed file".utf8).write(to: source)
        return (root, source, destination, try EasyMoveStore(journalDirectory: root.appendingPathComponent("journal"), activeUse: { _ in }))
    }

    func testDuplicateMoveLeavesNoSourceLinkAndCanRestore() async throws {
        let (_, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination, leaveSourceLink: false, destinationName: "copy-report.txt")
        let record = try await store.execute(reviewedPlan: plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("reviewed file".utf8))
        _ = try await store.rollback(recordID: record.id)
        XCTAssertEqual(try Data(contentsOf: source), Data("reviewed file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testMoveLeavesLinkAndRestoresCurrentEditedContents() async throws {
        let (_, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        XCTAssertTrue(plan.sameVolume)
        let record = try await store.execute(reviewedPlan: plan)
        XCTAssertEqual(record.phase, .completed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), plan.destination.path)
        try Data("edited through link".utf8).write(to: source)
        let restored = try await store.rollback(recordID: record.id)
        XCTAssertEqual(restored.phase, .restored)
        XCTAssertEqual(try Data(contentsOf: source), Data("edited through link".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        let history = try await store.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].phase, .restored)
    }

    func testDirectoryMoveAndCurrentNewChildRestore() async throws {
        let (root, source, destination, store) = try fixture()
        let folder = root.appendingPathComponent("source/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("report.txt"))
        let plan = try await store.prepare(source: folder, destinationFolder: destination)
        let record = try await store.execute(reviewedPlan: plan)
        try Data("new child".utf8).write(to: folder.appendingPathComponent("new.txt"))
        _ = try await store.rollback(recordID: record.id)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("new.txt")), Data("new child".utf8))
    }

    func testStaleReviewAndCollisionDoNotMoveSource() async throws {
        let (_, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        try Data("changed file".utf8).write(to: source)
        do { _ = try await store.execute(reviewedPlan: plan); XCTFail("changed source was moved") } catch { }
        XCTAssertEqual(try Data(contentsOf: source), Data("changed file".utf8))
        try Data("destination owner".utf8).write(to: destination.appendingPathComponent(source.lastPathComponent))
        do { _ = try await store.prepare(source: source, destinationFolder: destination); XCTFail("collision accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)), Data("destination owner".utf8))
    }

    func testSymlinkTreeSensitivePathAndExclusionsAreRefused() async throws {
        let (root, source, destination, store) = try fixture()
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias"), withDestinationURL: source)
        do { _ = try await store.prepare(source: folder, destinationFolder: destination); XCTFail("symlink tree accepted") } catch { }
        do { _ = try await store.prepare(source: source, destinationFolder: destination, excludedFolders: [folder.path]); XCTFail("exclusion ignored") } catch { }
        let secret = folder.appendingPathComponent(".env.local")
        try Data("fixture only".utf8).write(to: secret)
        do { _ = try await store.prepare(source: secret, destinationFolder: destination); XCTFail("sensitive file accepted") } catch { }
    }

    func testReplacedOwnedLinkIsNeverRemoved() async throws {
        let (root, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        let record = try await store.execute(reviewedPlan: plan)
        let oldLink = root.appendingPathComponent("original-link")
        try FileManager.default.moveItem(at: source, to: oldLink)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: root)
        do { _ = try await store.rollback(recordID: record.id); XCTFail("replacement link removed") } catch { }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testActiveUseBlocksReview() async throws {
        let (root, source, destination, _) = try fixture()
        let store = try EasyMoveStore(journalDirectory: root.appendingPathComponent("blocked-journal"), activeUse: { _ in throw EasyMoveError.unsafe("fixture active process") })
        do { _ = try await store.prepare(source: source, destinationFolder: destination); XCTFail("active use ignored") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // Exercise the real verified copy/delete/restore path on disposable fixtures
    // without requiring a mounted external volume on the test machine.
    func testCopyStrategyVerifiesDirectoryAndRestoresDestinationEdits() async throws {
        let (root, source, destination, store) = try fixture()
        let folder = root.appendingPathComponent("source/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("report.txt"))
        let original = try await store.prepare(source: folder, destinationFolder: destination)
        let plan = EasyMovePlan(id: original.id, source: original.source, destination: original.destination,
            bytes: original.bytes, copyRequired: true, sourceParent: original.sourceParent,
            destinationParent: original.destinationParent, manifest: original.manifest, exclusions: original.exclusions)
        let record = try await store.execute(reviewedPlan: plan)
        XCTAssertEqual(record.phase, .completed)
        try Data("edited copy".utf8).write(to: folder.appendingPathComponent("report.txt"))
        _ = try await store.rollback(recordID: record.id)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("report.txt")), Data("edited copy".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceBackup.path))
    }

    private func writeJournal(_ record: EasyMoveRecord, root: URL) throws {
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("journal/" + record.id.uuidString + ".json"))
    }
    private func identity(_ url: URL) throws -> EasyMoveIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw EasyMoveError.failed("fixture identity") }
        return EasyMoveIdentity(value)
    }

    func testInterruptedExclusiveRenameRecoversFromPreparedJournal() async throws {
        let (root, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        let record = EasyMoveRecord(plan: plan, created: Date(), phase: .prepared)
        try writeJournal(record, root: root)
        // Simulate termination between the exclusive rename and journal update.
        try FileManager.default.moveItem(at: source, to: plan.destination)
        let restored = try await store.rollback(recordID: record.id)
        XCTAssertEqual(restored.phase, .restored)
        XCTAssertEqual(try Data(contentsOf: source), Data("reviewed file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testInterruptedCopyWithOriginalStillPresentRestoresCurrentCopy() async throws {
        let (root, source, destination, store) = try fixture()
        let original = try await store.prepare(source: source, destinationFolder: destination)
        let plan = EasyMovePlan(id: original.id, source: original.source, destination: original.destination,
            bytes: original.bytes, copyRequired: true, sourceParent: original.sourceParent,
            destinationParent: original.destinationParent, manifest: original.manifest, exclusions: original.exclusions)
        try FileManager.default.copyItem(at: source, to: plan.destination)
        var record = EasyMoveRecord(plan: plan, created: Date(), phase: .destinationReady)
        record.destinationIdentity = try identity(plan.destination)
        try writeJournal(record, root: root)
        try Data("edited copy".utf8).write(to: plan.destination)
        let restored = try await store.rollback(recordID: record.id)
        XCTAssertEqual(restored.phase, .restored)
        XCTAssertEqual(try Data(contentsOf: source), Data("edited copy".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceBackup.path))
    }

    func testUnjournaledSourceLinkRecoversAfterSourceStagedCrash() async throws {
        let (root, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        var record = EasyMoveRecord(plan: plan, created: Date(), phase: .sourceStaged)
        try FileManager.default.moveItem(at: source, to: plan.destination)
        record.destinationIdentity = try identity(plan.destination)
        try writeJournal(record, root: root)
        // Crash after symlink creation but before its identity/linked phase saved.
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: plan.destination)
        let restored = try await store.rollback(recordID: record.id)
        XCTAssertEqual(restored.phase, .restored)
        XCTAssertEqual(try Data(contentsOf: source), Data("reviewed file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testChangedDestinationParentBlocksExecution() async throws {
        let (root, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("original-destination"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do { _ = try await store.execute(reviewedPlan: plan); XCTFail("replaced parent accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: source), Data("reviewed file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testReplacedDestinationCannotBeRemovedByRestore() async throws {
        let (root, source, destination, store) = try fixture()
        let plan = try await store.prepare(source: source, destinationFolder: destination)
        let record = try await store.execute(reviewedPlan: plan)
        try FileManager.default.moveItem(at: plan.destination, to: root.appendingPathComponent("original-destination-file"))
        try Data("another owner's file".utf8).write(to: plan.destination)
        do { _ = try await store.rollback(recordID: record.id); XCTFail("replacement destination accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("another owner's file".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), plan.destination.path)
    }

    func testSymlinkDestinationAncestorIsRefused() async throws {
        let (root, source, destination, store) = try fixture()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        do { _ = try await store.prepare(source: source, destinationFolder: alias); XCTFail("symlink ancestor accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
