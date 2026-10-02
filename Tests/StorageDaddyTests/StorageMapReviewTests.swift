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
    @Test func nativeMapInspectorCapturesAreOffscreen() async throws {
        let m = ExplorerModel(); let scan = fixture(); m.scan = scan; m.mapIndex = StorageMapIndex(scan: scan)
        m.volumeFree = 45_000_000_000; m.volumeCapacity = 500_000_000_000; m.selected = 8
        m.refreshFocus()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/map-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The historical 880-point component is wider and taller than the
        // detail area of an 880x600 app window. Reserve the ideal 200-point
        // sidebar and 100 points for stage controls/status in a second probe.
        // This is a content-budget fixture, not a full NavigationSplitView or
        // native window acceptance test. It never activates the application.
        let sizes = [(880, 1000, "880"), (1200, 1000, "1200"), (1440, 1000, "1440"),
                     (680, 500, "shell-budget-880x600")]
        for (width, height, label) in sizes {
            for state in ["bytes", "files", "filter", "staged"] {
                m.mapMeasure = state == "files" ? .files : .bytes
                m.search = state == "filter" ? "report" : ""
                m.staged = state == "staged" ? [3] : []
                try await Task.sleep(for: .milliseconds(30))
                #expect(!m.visible.isEmpty)
                let view = HStack(spacing: 0) { StorageExplorePanel(inspector: .constant(true)); Divider(); InspectorView().frame(width: 250) }
                    .environmentObject(m).preferredColorScheme(.dark).tint(Tints.mint).buttonStyle(StorageButtonStyle()).background(Color.black).frame(width: CGFloat(width), height: CGFloat(height))
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                #expect(host.bounds.width == CGFloat(width))
                #expect(host.bounds.height == CGFloat(height))
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                for scroll in scrollViews(host) { scroll.scrollerStyle = .overlay; scroll.tile() }
                host.layoutSubtreeIfNeeded()
                let overflowingDocuments = scrollViews(host).filter { scroll in
                    guard let document = scroll.documentView else { return false }
                    return document.bounds.width > scroll.contentView.bounds.width + 1
                }
                #expect(overflowingDocuments.isEmpty, "\(state), \(label)")
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(state)-\(label).png"))
            }
        }
    }

    @Test func compactFullShellJourneyUsesOnlySyntheticState() async throws {
        let m = ExplorerModel(); let scan = fixture()
        m.scan = scan; m.mapIndex = StorageMapIndex(scan: scan); m.selected = 8
        m.volumeFree = 45_000_000_000; m.volumeCapacity = 500_000_000_000
        m.progress = "Synthetic scan · Nothing moved"; m.refreshFocus()
        let wasActive = NSApplication.shared.isActive
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/compact-map")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (width, height) in [(880, 600), (1200, 850), (1440, 900)] {
            let states = ["bytes", "files", "filter", "staged", "inspector-hidden"]
                + (width == 880 ? MapMode.allCases.filter { $0 != .treemap }.map(\.rawValue) : [])
            for state in states {
                m.mode = MapMode(rawValue: state) ?? .treemap
                m.mapMeasure = state == "files" ? .files : .bytes
                m.search = state == "filter" ? "report" : ""
                // A visual staging fixture only: no stage/preflight/Trash action.
                m.staged = state == "staged" ? [7] : []
                try await Task.sleep(for: .milliseconds(30))
                #expect(!m.visible.isEmpty)
                let view = ExplorerView(runsLaunchActions: false, inspector: state != "inspector-hidden")
                    .environmentObject(m).frame(width: CGFloat(width), height: CGFloat(height))
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                #expect(host.bounds.width == CGFloat(width)); #expect(host.bounds.height == CGFloat(height))
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                // Pin only these offscreen views, not the user's preferences.
                // The first detached NavigationSplitView otherwise caches a
                // legacy-scroller gutter before SwiftUI adopts overlay scrollbars.
                for scroll in scrollViews(host) { scroll.scrollerStyle = .overlay; scroll.tile() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                for scroll in scrollViews(host) {
                    if let document = scroll.documentView {
                        #expect(document.bounds.width <= scroll.contentView.bounds.width + 1, "\(state), \(width): \(document.bounds.width) / \(scroll.contentView.bounds.width)")
                    }
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("shell-\(state.replacingOccurrences(of: " ", with: "-"))-\(width).png"))
                if state == "staged" {
                    for scroll in scrollViews(host) {
                        guard let document = scroll.documentView,
                              document.bounds.height > scroll.contentView.bounds.height else { continue }
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    host.layoutSubtreeIfNeeded()
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("shell-staged-scrolled-\(width).png"))
                }
                #expect(NSApplication.shared.isActive == wasActive)
                #expect(m.scan?.nodes.map(\.allocatedBytes) == scan.nodes.map(\.allocatedBytes))
                #expect(m.scan?.rootPath == scan.rootPath)
                #expect(m.lastTrashedURLs.isEmpty)
            }
        }
        m.openStorage(.developer); #expect(m.storageSection == .developer)
        m.openStorage(.explore); #expect(m.storageSection == .explore)
        #expect(m.workspace == .explore); #expect(m.lastTrashedURLs.isEmpty)
    }
}
