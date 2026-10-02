import DiskCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import StorageDaddy

private func duplicateReviewFixture(allocations: [Int64] = [4096, 8192, 0]) -> (ScanResult, DuplicateGroup) {
    let nodes = [DiskNode(id: 0, parent: nil, name: "", isDirectory: true)] + allocations.enumerated().map { index, bytes in
        DiskNode(id: index + 1, parent: 0, name: "copy-\(index + 1).bin", isDirectory: false,
                 logicalBytes: 16384, allocatedBytes: bytes)
    }
    return (ScanResult(rootPath: "/tmp/storage-duplicate-fixture", nodes: nodes, started: .distantPast),
            DuplicateGroup(id: "fixture", nodeIDs: Array(1...allocations.count), wastedBytes: 999999))
}

@Test func duplicateReviewStartsWithNothingSelectedForCleanup() {
    let (scan, group) = duplicateReviewFixture()
    let review = DuplicateReviewSelection(group: group, scan: scan)
    #expect(review.survivorIDs == [1, 2, 3])
    #expect(review.removalIDs.isEmpty)
    #expect(review.allocatedUpperBound == 0)
    #expect(!review.canStage)
    var callbacks = 0
    review.stage { _ in callbacks += 1 }
    #expect(callbacks == 0)
}

@Test func duplicateReviewCannotStageEveryCopy() {
    let (scan, group) = duplicateReviewFixture()
    var review = DuplicateReviewSelection(group: group, scan: scan)
    let firstChanged = review.setSurvivor(1, kept: false)
    let secondChanged = review.setSurvivor(2, kept: false)
    let lastChanged = review.setSurvivor(3, kept: false)
    #expect(firstChanged)
    #expect(secondChanged)
    #expect(!lastChanged)
    #expect(review.survivorIDs == [3])
    var staged: [Int] = []
    review.stage { staged = $0 }
    #expect(staged == [1, 2])
    #expect(Set(staged).isDisjoint(with: review.survivorIDs))
    #expect(staged.count < group.nodeIDs.count)
}

@Test func duplicateReviewChangingSurvivorsChangesRemovalsAndAllocatedUpperBound() {
    let (scan, group) = duplicateReviewFixture()
    var review = DuplicateReviewSelection(group: group, scan: scan)
    review.setSurvivor(2, kept: false)
    #expect(review.removalIDs == [2])
    #expect(review.allocatedUpperBound == 8192)
    review.setSurvivor(3, kept: false)
    #expect(review.removalIDs == [2, 3])
    #expect(review.allocatedUpperBound == 8192)
    review.setSurvivor(2, kept: true)
    review.setSurvivor(1, kept: false)
    #expect(review.survivorIDs == [2])
    #expect(review.removalIDs == [1, 3])
    #expect(review.allocatedUpperBound == 4096)
    // The finder estimate assumes a different survivor; the review must not use it.
    #expect(review.allocatedUpperBound != group.wastedBytes)
    var staged: [Int] = []
    review.stage { staged = $0 }
    #expect(staged == [1, 3])
}

@Test func duplicateReviewSupportsMultipleSurvivorsAndZeroAllocatedRemoval() {
    let (scan, group) = duplicateReviewFixture()
    var review = DuplicateReviewSelection(group: group, scan: scan)
    review.setSurvivor(3, kept: false)
    #expect(review.survivorIDs == [1, 2])
    #expect(review.removalIDs == [3])
    #expect(review.allocatedUpperBound == 0)
    #expect(review.canStage)
    let unknownKept = review.setSurvivor(99, kept: true)
    let unknownRemoved = review.setSurvivor(99, kept: false)
    #expect(!unknownKept)
    #expect(!unknownRemoved)
    #expect(review.survivorIDs == [1, 2])
}

@Test func duplicateReviewRejectsInvalidGroupEvidence() {
    let (scan, _) = duplicateReviewFixture()
    for ids in [[1], [1, 1], [1, 99], [0, 1], [-1, 1]] {
        let group = DuplicateGroup(id: "invalid", nodeIDs: ids, wastedBytes: 0)
        var review = DuplicateReviewSelection(group: group, scan: scan)
        #expect(!review.isValid)
        let changed = review.setSurvivor(1, kept: false)
        #expect(!changed)
        #expect(review.removalIDs.isEmpty)
        #expect(review.allocatedUpperBound == nil)
        var called = false
        review.stage { _ in called = true }
        #expect(!called)
    }
}

@Test func duplicateReviewRejectsNegativeAllocationSymlinksAndDirectories() {
    let (scan, group) = duplicateReviewFixture()
    for variant in 0..<4 {
        var changed = scan
        switch variant {
        case 0: changed.nodes[2].allocatedBytes = -1
        case 1: changed.nodes[2].isSymlink = true
        case 2: changed.nodes[2].isDirectory = true
        default: changed.nodes[2].id = 99
        }
        let review = DuplicateReviewSelection(group: group, scan: changed)
        #expect(!review.isValid)
        #expect(!review.canStage)
    }
}

@Test func duplicateReviewAllocationOverflowCannotStage() {
    let (scan, group) = duplicateReviewFixture(allocations: [1, .max, 1])
    var review = DuplicateReviewSelection(group: group, scan: scan)
    review.setSurvivor(2, kept: false)
    review.setSurvivor(3, kept: false)
    #expect(review.allocatedUpperBound == nil)
    #expect(!review.canStage)
    var called = false
    review.stage { _ in called = true }
    #expect(!called)
}

/// Fixture-only, offscreen evidence. Does not launch or activate StorageDaddy,
/// create a visible window, inspect real files, or invoke any cleanup callback.
@MainActor @Test func duplicateReviewOffscreenCaptures() throws {
    _ = NSApplication.shared
    var (scan, group) = duplicateReviewFixture()
    scan.rootPath = "/tmp/storage-duplicate-fixture/Design exports/Archive/Approved assets"
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let output = root.appendingPathComponent(".build/duplicate-review-captures")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for width in [880, 1200, 1440] {
        try captureDuplicateReview(
            DuplicateReviewView(scan: scan, groups: [group], isLoading: false, error: nil,
                                onFind: {}, onCancel: {}, onStage: { _ in }, hasSearched: true),
            width: width, output: output.appendingPathComponent("duplicates-\(width).png"))
    }
    for state in ["unknown", "loading", "empty", "error"] {
        try captureDuplicateReview(
            DuplicateReviewView(scan: scan, groups: [], isLoading: state == "loading",
                                error: state == "error" ? "A fixture file changed during the check. Try again." : nil,
                                onFind: {}, onCancel: {}, onStage: { _ in }, hasSearched: state != "unknown"),
            width: 880, output: output.appendingPathComponent("duplicates-\(state)-880.png"))
    }
}

@MainActor private func captureDuplicateReview(_ view: DuplicateReviewView, width: Int, output: URL) throws {
    let size = NSSize(width: width, height: 720)
    let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: 720).preferredColorScheme(.dark))
    // Supply an unshown backing window for reliable text layout. Never order it
    // front, make it key, or activate the application.
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    // Let SwiftUI finish its initial offscreen render before caching display.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    host.layoutSubtreeIfNeeded()
    host.setNeedsDisplay(host.bounds)
    host.display()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: output)
    #expect(bitmap.pixelsWide >= width)
    #expect(bitmap.pixelsHigh >= 720)
}
