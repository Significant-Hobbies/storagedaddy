import AppKit
import SwiftUI
import XCTest
import DiskCore
@testable import StorageDaddy

@MainActor
final class ProjectPurgeViewTests: XCTestCase {
    private func fixture(verified: Bool = true) -> (ScanResult, [ProjectPurgeRecord]) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-30 * 86400)
        let scan = ScanResult(rootPath: "/fixture/projects", nodes: [
            DiskNode(id: 0, parent: nil, name: "projects", isDirectory: true, modified: old),
            DiskNode(id: 1, parent: 0, name: "app", isDirectory: true, modified: old),
            DiskNode(id: 2, parent: 1, name: "Package.swift", isDirectory: false, modified: old),
            DiskNode(id: 3, parent: 1, name: ".build", isDirectory: true, modified: old),
            DiskNode(id: 4, parent: 3, name: "output", isDirectory: false, allocatedBytes: 100, modified: old)
        ], started: now)
        let report = DeveloperReport.build(scan: scan, groups: DeveloperInsights.analyze(scan))
        let probes: [Int: ProjectPurgeProbe] = verified ? [1: ProjectPurgeProbe(
            git: .verified(trackedNodeIDs: [], checkoutRootIDs: []), rebuildability: [3: "Fixture verified restoration"])] : [:]
        return (scan, ProjectPurgeReview.build(scan: scan, report: report, probes: probes, now: now))
    }

    func testFocusDoesNotSelectAndCallbackOnlyStagesExplicitArtifacts() {
        let (_, records) = fixture()
        var state = ProjectPurgeSelectionState()
        XCTAssertNil(state.focusedProjectID)
        XCTAssertTrue(state.artifactIDs.isEmpty)
        state.focusedProjectID = 1
        XCTAssertTrue(state.artifactIDs.isEmpty)
        state.set(1, selected: true, records: records)
        XCTAssertTrue(state.artifactIDs.isEmpty)
        state.set(3, selected: true, records: records)
        var received: [[Int]] = []
        XCTAssertFalse(state.stage(records: records, status: .loading) { received.append($0) })
        XCTAssertFalse(state.stage(records: records, status: .error("Fixture error")) { received.append($0) })
        XCTAssertTrue(state.stage(records: records, status: .ready) { received.append($0) })
        XCTAssertEqual(received, [[3]])
        let (_, blocked) = fixture(verified: false)
        XCTAssertFalse(state.stage(records: blocked, status: .ready) { received.append($0) })
        XCTAssertEqual(received, [[3]])
        state.reset()
        XCTAssertNil(state.focusedProjectID)
        XCTAssertTrue(state.artifactIDs.isEmpty)
    }

    func testBlockedArtifactsCannotBeSelected() {
        let (_, records) = fixture(verified: false)
        var state = ProjectPurgeSelectionState()
        state.set(3, selected: true, records: records)
        XCTAssertTrue(state.artifactIDs.isEmpty)
    }

    func testRecoveryPlanSubmissionRequiresTextAndFreshOwnerAcknowledgement() {
        var draft = ProjectPurgeRecoveryPlanState(artifactID: 3)
        var received: [(Int, String?)] = []
        let callback: (Int, String?) -> Void = { received.append(($0, $1)) }
        XCTAssertFalse(draft.canSubmit)
        XCTAssertFalse(draft.submit(callback: callback))
        draft.text = "\n \t"
        draft.ownerReviewed = true
        XCTAssertFalse(draft.canSubmit)
        XCTAssertFalse(draft.submit(callback: callback))
        draft.text = "  My own reviewed recovery procedure.\n"
        XCTAssertFalse(draft.ownerReviewed)
        XCTAssertFalse(draft.submit(callback: callback))
        draft.ownerReviewed = true
        XCTAssertTrue(draft.canSubmit)
        XCTAssertFalse(draft.submit(callback: nil))
        XCTAssertTrue(draft.submit(callback: callback))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].0, 3)
        XCTAssertEqual(received[0].1, "My own reviewed recovery procedure.")
        draft.text += " Edited"
        XCTAssertFalse(draft.ownerReviewed)
        XCTAssertFalse(draft.submit(callback: callback))
        XCTAssertFalse(draft.clear(callback: callback))
        let existing = ProjectPurgeRecoveryPlanState(artifactID: 3, existingPlan: "Saved plan")
        XCTAssertFalse(existing.ownerReviewed)
        XCTAssertFalse(existing.submit(callback: callback))
        XCTAssertTrue(existing.clear(callback: callback))
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[1].0, 3)
        XCTAssertNil(received[1].1)
    }

    func testSavingPlanNeverSelectsOrStagesAndSheetLayoutsOffscreen() {
        let (scan, records) = fixture(verified: false)
        let selection = ProjectPurgeSelectionState()
        var draft = ProjectPurgeRecoveryPlanState(artifactID: 3)
        draft.text = "Owner-authored recovery plan"
        draft.ownerReviewed = true
        var plans = 0, stages = 0
        XCTAssertTrue(draft.submit { id, plan in
            XCTAssertEqual(id, 3); XCTAssertEqual(plan, draft.text); plans += 1
        })
        XCTAssertTrue(selection.artifactIDs.isEmpty)
        XCTAssertNil(selection.focusedProjectID)
        XCTAssertFalse(selection.stage(records: records, status: .ready) { _ in stages += 1 })
        let sheet = NSHostingView(rootView: ProjectPurgeRecoveryPlanSheet(draft: draft) { _, _ in plans += 1 })
        sheet.frame = NSRect(x: 0, y: 0, width: 568, height: 540)
        sheet.layoutSubtreeIfNeeded()
        let view = NSHostingView(rootView: ProjectPurgeView(records: records, scan: scan, status: .ready,
            onRecoveryPlan: { _, _ in plans += 1 }, onStageArtifactIDs: { _ in stages += 1 }))
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 700)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(sheet.fittingSize.height, 0)
        XCTAssertEqual(plans, 1)
        XCTAssertEqual(stages, 0)
    }

    func testNativeFixtureLayoutDoesNotInvokeStageOrActivateApp() {
        let (scan, records) = fixture()
        var callbacks = 0
        for width: CGFloat in [480, 960] {
            for status: ProjectPurgeViewStatus in [.ready, .loading, .error("Fixture error"), .idle("Scan a folder")] {
                let view = NSHostingView(rootView: ProjectPurgeView(records: records, scan: scan, status: status) { _ in callbacks += 1 })
                view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(view.fittingSize.height, 0)
            }
        }
        XCTAssertEqual(callbacks, 0)
    }
}
