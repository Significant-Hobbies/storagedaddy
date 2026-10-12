import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DiskCore
@testable import StorageDaddy

private func signingCopyScan() -> ScanResult {
    let count = 315
    let bytes: Int64 = 1_500_000_000
    let old = Date().addingTimeInterval(-3 * 86400)
    var nodes = [DiskNode(id: 0, parent: nil, name: "com.google.Chrome.code_sign_clone", isDirectory: true,
                          logicalBytes: bytes * Int64(count), allocatedBytes: bytes, modified: old, children: Array(1...count))]
    for id in 1...count {
        nodes.append(DiskNode(id: id, parent: 0, name: String(format: "code_sign_clone.%06d", id), isDirectory: true,
                              logicalBytes: bytes, allocatedBytes: id == 1 ? bytes : 0, modified: old, children: [id + count]))
    }
    for id in 1...count {
        nodes.append(DiskNode(id: id + count, parent: id, name: "Google Chrome Framework", isDirectory: false,
                              logicalBytes: bytes, allocatedBytes: id == 1 ? bytes : 0, modified: old))
    }
    var scan = ScanResult(rootPath: "/private/var/folders/zz/StorageDaddy (test fixture)/X/com.google.Chrome.code_sign_clone", nodes: nodes)
    scan.fileAllocationDetails = (1...count).map {
        .init(nodeID: $0 + count, reportedBytes: bytes, privateBytes: 0, sharesStorage: true, linkCount: 1)
    }
    return scan
}

@MainActor @Test func sharedCopyCleanupKeepsZeroByteItemsAndRecoveryUnknownsHonest() {
    let model = ExplorerModel(); let scan = signingCopyScan()
    model.scan = scan; model.allocationIndex = StorageAllocationIndex(scan: scan)
    model.staged = [2]
    #expect(model.stagedExclusiveBytes == 0)
    #expect(model.folderSizeDescription(scan.nodes[2]).contains("Shared storage"))
    #expect(model.itemSizeDescription(scan.nodes[2]) == "Shared")
    #expect(ChromeSigningClones.copyIDs(in: scan, storeID: 0).count == 315)
    model.staged = [1, 2]
    #expect(model.stagedExclusiveBytes == 0)
    model.allocationIndex = nil
    #expect(model.stagedExclusiveBytes == nil)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_SHARED_STORAGE_EVIDENCE"] == "1"))
func sharedStorageNativeFixtures() async throws {
    let scan = signingCopyScan()
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".fleet-local/shared-storage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for width in [880, 1200, 1440] {
        for state in ["copies", "inspector", "cleanup"] {
            let model = ExplorerModel()
            model.scan = scan; model.allocationIndex = StorageAllocationIndex(scan: scan)
            model.mapIndex = StorageMapIndex(scan: scan); model.volumeFree = 58_000_000_000
            model.focus = 0; model.selected = state == "inspector" ? 2 : nil
            model.staged = state == "cleanup" ? [2] : []
            model.openStorage(state == "cleanup" ? .cleanup : .explore)
            model.progress = "Synthetic shared-copy fixture · No filesystem scan or cleanup"
            model.refreshFocus()
            let host = NSHostingView(rootView: ExplorerView(runsLaunchActions: false).environmentObject(model)
                .preferredColorScheme(.dark).frame(width: CGFloat(width), height: 1000))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(150))
            if state == "inspector" { model.inspectSearchResult(2) }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(state)-\(width).png"))
            #expect(model.staged == (state == "cleanup" ? [2] : []), "Rendering must not stage or move items")
        }
    }
}
