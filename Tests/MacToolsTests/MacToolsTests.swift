import XCTest
@testable import MacTools

final class MacToolsTests: XCTestCase {
    @MainActor func testUpdatesWaitForControlsReviewAndOperations() {
        let model = AppModel(loadSystem: false)
        model.states = Dictionary(uniqueKeysWithValues: Tweaks.all.map { ($0.id, .notApplied) })
        let session = MacToolsSession(model: model)
        XCTAssertTrue(session.allowsUpdateInstallation)
        model.toggle(Tweaks.tweak("file-extensions")!, true)
        XCTAssertFalse(session.allowsUpdateInstallation)
        model.wanted = []
        model.run = .working("Removing models")
        XCTAssertTrue(session.isBusy)
        XCTAssertFalse(session.allowsUpdateInstallation)
        model.run = .finished(problems: [], freed: nil)
        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(session.allowsUpdateInstallation)
        model.dismissRun()
        XCTAssertTrue(session.allowsUpdateInstallation)
    }
    func testKeptFeaturesRetainSharedModels() {
        XCTAssertFalse(Catalog.setsToRemove(keeping: ["writing-tools"]).contains(Catalog.foundationModels))
        XCTAssertTrue(Catalog.setsToRemove(keeping: ["writing-tools"]).contains(Catalog.codeModels))
        XCTAssertTrue(Catalog.setsToRemove(keeping: Set(Catalog.features.map(\.id))).isEmpty)
    }
    func testProfileOwnershipAndSelectedFeatures() throws {
        let data = try Profile.data(Profile.Contents(ai: ["writing-tools"], tweaks: ["analytics"]))
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "com.significanthobbies.storagedaddy.apple-intelligence")
        XCTAssertEqual(profile["PayloadRemovalDisallowed"] as? Bool, false)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("allowWritingTools"))
        XCTAssertTrue(text.contains("allowGenmoji"))
        XCTAssertFalse(text.contains(Profile.downloadKey(Catalog.modelSet(Catalog.foundationModels)!)))
        XCTAssertTrue(text.contains(Profile.downloadKey(Catalog.modelSet(Catalog.codeModels)!)))
    }
    func testUnknownSizesAndChangedAssetTypesArePreserved() throws {
        XCTAssertNil(Models.total(["first", "second"], read: { $0 == "first" ? 100 : nil }))
        let split = try Models.matching([Catalog.foundationModels], assetType: { _ in "changed.asset.type" })
        XCTAssertTrue(split.matched.isEmpty)
        XCTAssertEqual(split.skipped.count, 1)
        XCTAssertThrowsError(try Models.matching(["unknown.model"], assetType: { _ in nil }))
        XCTAssertEqual(Settings.modelState(["unknown"], read: { _ in nil }), .unknown)
        XCTAssertThrowsError(try Models.remove([Catalog.foundationModels], approval: { false }))
    }
    func testExplicitPartialUndoIsInReviewedPlan() {
        var snapshot = Snapshot()
        snapshot.profile = Profile.Installed()
        let partial = Tweaks.tweak("smart-punctuation")!
        let plan = Plan.make(wanted: [], ai: nil, undo: [partial.id], snapshot: snapshot,
                             state: { $0.id == partial.id ? .partial : .notApplied })
        XCTAssertEqual(plan.revert.map(\.id), [partial.id])
        XCTAssertTrue(plan.models.isEmpty)
        XCTAssertNil(plan.profile)
    }
    func testCleanupRejectsChangedCandidates() {
        let reviewed = StorageItem(id: "simulators", title: "Simulators", detail: "", kind: .simulators,
                                   paths: ["/example/old"], bytes: 10, count: 1)
        var changed = reviewed
        changed.paths.append("/example/new")
        XCTAssertTrue(Storage.reviewStillMatches([reviewed], current: [reviewed]))
        XCTAssertFalse(Storage.reviewStillMatches([reviewed], current: [changed]))
        changed = reviewed; changed.bytes = 11
        XCTAssertFalse(Storage.reviewStillMatches([reviewed], current: [changed]))
        XCTAssertFalse(Storage.reviewStillMatches([reviewed], current: []))
        changed = reviewed
        changed.identities["/example/old"] = .init(device: 1, inode: 2)
        XCTAssertFalse(Storage.reviewStillMatches([reviewed], current: [changed]))
    }
    func testUndoJournalWriteFailureStopsChanges() throws {
        let original = Engine.folder
        let originalBlocked = Engine.journalBlocked
        defer { Engine.folder = original; Engine.journalBlocked = originalBlocked }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file instead of directory".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        Engine.folder = temporary
        Engine.journalBlocked = nil
        XCTAssertFalse(Engine.save(Engine.Journal()))
        XCTAssertNotNil(Engine.journalBlocked)
        let originalLaunchctl = Engine.launchctl
        defer { Engine.launchctl = originalLaunchctl }
        var arguments: [[String]] = []
        Engine.launchctl = { arguments.append($0); return Shell.Result(status: 0, output: "") }
        var journal = Engine.Journal()
        XCTAssertFalse(Engine.disableService("example.test", tweak: "test", journal: &journal).isEmpty)
        XCTAssertFalse(arguments.contains { $0.first == "disable" || $0.first == "bootout" })
    }
}
