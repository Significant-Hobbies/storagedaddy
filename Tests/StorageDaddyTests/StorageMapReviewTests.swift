import AppKit
import SwiftUI
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct StorageMapReviewTests {
    private func fixture() -> ScanResult {
        ScanResult(rootPath: "/tmp/storage-map-fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "Fixture", isDirectory: true, allocatedBytes: 900_000_000, children: [1, 7, 8, 9]),
            DiskNode(id: 1, parent: 0, name: "Portfolio workspace", isDirectory: true, allocatedBytes: 170_000_000, children: [2, 3, 5]),
            DiskNode(id: 2, parent: 1, name: "package.json", isDirectory: false, allocatedBytes: 4_000),
            DiskNode(id: 3, parent: 1, name: "node_modules", isDirectory: true, allocatedBytes: 120_000_000, children: [4]),
            DiskNode(id: 4, parent: 3, name: "dependency.js", isDirectory: false, allocatedBytes: 120_000_000),
            DiskNode(id: 5, parent: 1, name: ".git", isDirectory: true, allocatedBytes: 50_000_000, children: [6]),
            DiskNode(id: 6, parent: 5, name: "pack", isDirectory: false, allocatedBytes: 50_000_000),
            DiskNode(id: 7, parent: 0, name: "recording.mov", isDirectory: false, allocatedBytes: 700_000_000),
            DiskNode(id: 8, parent: 0, name: "report.pdf", isDirectory: false, allocatedBytes: 30_000_000),
            DiskNode(id: 9, parent: 0, name: "Empty folder", isDirectory: true)
        ])
    }
    @Test func projectionAndFilterKeepScopeAndUnknownCapacityHonest() {
        let m = ExplorerModel(); m.scan = fixture(); m.mapIndex = StorageMapIndex(scan: m.scan!)
        #expect(m.projectedFreeUpperBound == nil)
        m.volumeFree = 100; m.volumeCapacity = 1_000_000_000; m.staged = [3]
        #expect(m.projectedFreeUpperBound == 120_000_100)
        #expect(m.hasAncestor(4, in: m.staged))
        #expect(!m.hasAncestor(6, in: m.staged))
        let before = Set(m.mapItems.map(\.id)); m.search = "report"
        #expect(Set(m.mapItems.map(\.id)) == before)
        #expect(m.matchesFilter(m.scan!.nodes[8])); #expect(!m.matchesFilter(m.scan!.nodes[7]))
        m.mapMeasure = .files
        #expect(m.mapWeight(m.scan!.nodes[1]) == 3)
        #expect(m.mapWeight(m.scan!.nodes[9]) == 0)
        m.volumeCapacity = 1_000
        #expect(m.projectedFreeUpperBound == 1_000)
    }
    @Test func ageRefreshPublishesOnlyCurrentScopeAndMeasure() async throws {
        let m = ExplorerModel(); m.scan = fixture(); m.mode = .age; m.search = "report"
        for _ in 0..<100 {
            if !m.ageRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.ageHistogram?.totalFiles == 1)
        m.ageGranularity = .yearly; m.ageGranularity = .quarterly; m.allocated = false
        for _ in 0..<100 {
            if !m.ageRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.ageHistogram?.granularity == .quarterly)
        #expect(m.ageHistogram?.allocated == false)
        #expect(m.ageHistogram?.totalBytes == 0)
        #expect(m.ageHistogramError == nil)
        m.search = ""; m.focus = 1
        for _ in 0..<100 {
            if !m.ageRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.ageHistogram?.totalFiles == 3)
    }
    @Test func duplicateReviewInvalidatesAndStagesEveryExplicitCopyThroughPreflight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-duplicate-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = Data(repeating: 42, count: 4096)
        for name in ["keep.bin", "review-a.bin", "review-b.bin"] {
            try contents.write(to: root.appendingPathComponent(name))
        }
        let scan = try await DiskScanner.scan(root: root)
        let m = ExplorerModel(); m.scan = scan
        m.findDuplicates()
        for _ in 0..<200 {
            if !m.duplicatesLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.duplicatesSearched); #expect(m.duplicatesError == nil)
        let group = try #require(m.duplicateGroups.first)
        #expect(group.nodeIDs.count == 3)
        let ids = scan.nodes.filter { $0.name.hasPrefix("review-") }.map(\.id)
        m.stageDuplicateCopies(ids)
        for _ in 0..<200 {
            if Set(ids).isSubset(of: m.staged), !m.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.staged == Set(ids)); #expect(m.message == nil)
        for name in ["keep.bin", "review-a.bin", "review-b.bin"] {
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == contents)
        }
        let originalKeep = try #require(scan.nodes.first { $0.name == "keep.bin" }?.id)
        let newKeep = try #require(ids.first)
        let revisedRemovals = group.nodeIDs.filter { $0 != newKeep }
        m.stageDuplicateCopies(revisedRemovals)
        for _ in 0..<200 {
            if Set(revisedRemovals).isSubset(of: m.staged), !m.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(m.staged == Set(revisedRemovals)); #expect(!m.staged.contains(newKeep))
        #expect(m.staged.contains(originalKeep))
        // An explicitly staged ancestor must be removed before its descendant
        // can be promised as a survivor; rejection changes no queued items.
        m.staged = [0]; m.stageDuplicateCopies(ids)
        #expect(m.staged == [0]); #expect(m.message?.contains("kept duplicate") == true)
        m.staged = []
        // Replacing a scan cancels any in-flight finder and removes old results.
        m.findDuplicates(); m.scan = fixture()
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.duplicateGroups.isEmpty); #expect(!m.duplicatesSearched)
        #expect(!m.duplicatesLoading); #expect(m.duplicatesError == nil)
    }
    @Test func nativeMapInspectorCapturesAreOffscreen() throws {
        let m = ExplorerModel(); let scan = fixture(); m.scan = scan; m.mapIndex = StorageMapIndex(scan: scan)
        m.volumeFree = 45_000_000_000; m.volumeCapacity = 500_000_000_000; m.selected = 8
        m.refreshFocus()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/map-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [880, 1200, 1440] {
            for state in ["bytes", "files", "filter", "staged"] {
                m.mapMeasure = state == "files" ? .files : .bytes
                m.search = state == "filter" ? "report" : ""
                m.staged = state == "staged" ? [3] : []
                let view = HStack(spacing: 0) { StorageExplorePanel(inspector: .constant(true)); Divider(); InspectorView().frame(width: 250) }
                    .environmentObject(m).preferredColorScheme(.dark).tint(Tints.mint).buttonStyle(StorageButtonStyle()).background(Color.black).frame(width: CGFloat(width), height: 1000)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                #expect(host.bounds.width == CGFloat(width))
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                for scroll in scrollViews(host) {
                    if let document = scroll.documentView { #expect(document.bounds.width <= scroll.contentView.bounds.width + 1) }
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(state)-\(width).png"))
            }
        }
    }
}
