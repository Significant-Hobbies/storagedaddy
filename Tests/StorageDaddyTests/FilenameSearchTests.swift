import AppKit
import SwiftUI
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct FilenameSearchTests {
    nonisolated private static var helperAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/FinderSearchSupport/storage-search").path)
    }
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/FinderSearchSupport/storage-search")
    }
    private func fixture() -> ScanResult {
        ScanResult(rootPath: "/tmp/FinderSearch demonstration", nodes: [
            DiskNode(id: 0, parent: nil, name: "Demonstration", isDirectory: true, children: [1, 3]),
            DiskNode(id: 1, parent: 0, name: "Projects", isDirectory: true, children: [2]),
            DiskNode(id: 2, parent: 1, name: "report-quarterly.pdf", isDirectory: false, logicalBytes: 3_000_000, allocatedBytes: 3_002_368, modified: Date()),
            DiskNode(id: 3, parent: 0, name: "report-quarterly.txt", isDirectory: false, logicalBytes: 4096, allocatedBytes: 4096, modified: Date())
        ])
    }
    @Test(.enabled(if: FilenameSearchTests.helperAvailable, "Requires prepared FinderSearch helper")) func bundledEngineSearchesMetadataAndReloadsReplacementScan() async throws {
        #expect(FileManager.default.isExecutableFile(atPath: helper.path), "Prepare FinderSearch support before integration tests")
        let engine = FinderSearchEngine(binary: helper)
        let scan = fixture(), identity = UUID()
        let matches = try await engine.search(scan: scan, identity: identity, query: "reprot ext:pdf mtime:<7d size:>1mb", scope: 0)
        #expect(matches.hits?.map(\.id) == [2])
        let scoped = try await engine.search(scan: scan, identity: identity, query: "report", scope: 1)
        #expect(scoped.hits?.map(\.id) == [2])
        let emptyScope = try await engine.search(scan: scan, identity: identity, query: "report in:/tmp/other", scope: 1)
        #expect(emptyScope.hits?.isEmpty == true)
        var replacement = scan; replacement.nodes[2].name = "new-summary.pdf"
        let replaced = try await engine.search(scan: replacement, identity: UUID(), query: "report", scope: 1)
        #expect(replaced.hits?.isEmpty == true)
        await #expect(throws: (any Error).self) {
            try await engine.search(scan: scan, identity: UUID(), query: "grep:contents", scope: 0)
        }
        // An engine error resets the transport and a later request recovers.
        let recovered = try await engine.search(scan: scan, identity: UUID(), query: "ext:txt", scope: 0)
        #expect(recovered.hits?.map(\.id) == [3])
    }
    @Test func missingHelperProducesActionableError() async {
        let engine = FinderSearchEngine(binary: URL(fileURLWithPath: "/nonexistent/storage-search"))
        let model = FilenameSearchModel(engine: engine)
        await model.update(scan: fixture(), identity: UUID(), query: "report", scope: 0)
        #expect(model.error?.contains("helper is missing") == true)
        #expect(!model.busy); #expect(model.hits.isEmpty)
    }
    private actor DelayedService: FilenameSearchService {
        func search(scan: ScanResult, identity: UUID, query: String, scope: Int) async throws -> FilenameSearchReply {
            // Deliberately ignore cancellation to test generation protection too.
            try? await Task.sleep(for: .milliseconds(query == "old" ? 250 : 5))
            return FilenameSearchReply(ok: true, error: nil, hits: [.init(id: query == "old" ? 2 : 3, score: 1)], took_us: 1)
        }
    }
    @Test func oldQueryCannotPublishAfterNewQueryOrClear() async throws {
        let model = FilenameSearchModel(engine: DelayedService()), scan = fixture(), identity = UUID()
        let old = Task { await model.update(scan: scan, identity: identity, query: "old", scope: 0) }
        try await Task.sleep(for: .milliseconds(175))
        await model.update(scan: scan, identity: identity, query: "new", scope: 0)
        await old.value
        #expect(model.hits.map(\.id) == [3]); #expect(!model.busy)
        await model.update(scan: scan, identity: identity, query: " ", scope: 0)
        #expect(model.hits.isEmpty); #expect(model.error == nil)
        let m = ExplorerModel(); m.scan = scan
        let first = m.filenameSearchIdentity; m.scan = scan
        #expect(first != m.filenameSearchIdentity)
        #expect(Workspace.findFiles.requiresScan)
        m.workspace = .findFiles
        let inspectorRequest = m.storageInspectorRequest
        m.inspectSearchResult(2)
        #expect(m.workspace == .explore); #expect(m.focus == 1); #expect(m.selected == 2)
        #expect(m.storageInspectorRequest != inspectorRequest)
    }
    @Test(.enabled(if: FilenameSearchTests.helperAvailable, "Requires prepared FinderSearch helper")) func searchSurfaceRendersAtSupportedNativeWidths() async throws {
        let m = ExplorerModel(); m.scan = fixture(); m.focus = 1
        let directory = helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/finder-search")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [680, 1000, 1240] {
            let model = FilenameSearchModel(engine: FinderSearchEngine(binary: helper))
            let view = FilenameSearchView(model: model, query: "reprot ext:pdf").environmentObject(m)
                .preferredColorScheme(.dark).tint(Tints.mint).frame(width: CGFloat(width), height: 560)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 560)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<100 {
                if !model.busy && model.hits.count == 1 { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(model.hits.map(\.id) == [2]); #expect(model.error == nil)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("results-\(width).png"))
        }
    }
}
