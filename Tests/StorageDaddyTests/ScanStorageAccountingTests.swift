@testable import DiskCore
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import StorageDaddy

private func accountingScan(path: String = "/System/Volumes/Data", bytes: Int64 = 476) -> ScanResult {
    ScanResult(rootPath: path, nodes: [DiskNode(id: 0, parent: nil, name: "Data", isDirectory: true, allocatedBytes: bytes)])
}

private func accountingCapacity() -> StartupCapacity {
    StartupCapacity(volumes: [MountedVolumeInfo(
        name: "Data", mountPoint: "/System/Volumes/Data", fsType: "apfs", bsdName: "disk3s5",
        totalCapacity: 1_000, availableCapacity: 147, importantAvailableCapacity: 200,
        isStartupData: true, isSystem: false, isInternal: true, isRemovable: false,
        isEjectable: false, isReadOnly: false, isNetwork: false, isEncrypted: nil,
        isDiskImage: false, apfsContainer: "disk3"
    )])!
}

@Test func scanAccountingSeparatesOccupiedRemainderFromFreeSpace() throws {
    let value = try #require(ScanStorageAccounting(scan: accountingScan(), capacity: accountingCapacity()))
    #expect(value.scanned == 476)
    #expect(value.outsideBreakdown == 377)
    #expect(value.capacity.available == 147)
    #expect(value.scanned + value.outsideBreakdown + value.capacity.available == value.capacity.total)
    #expect(!value.exceedsUsed)
}

@Test func scanAccountingListsMeasuredAPFSVolumesWithoutCountingThemAsScannedFiles() throws {
    let apfs = StartupAPFSAccounting(measuredAt: Date(), total: 1_000, available: 147,
        volumes: [
            StartupAPFSAccounting.Volume(name: "Data", roles: ["Data"], bytes: 800, device: "disk3s5"),
            StartupAPFSAccounting.Volume(name: "System", roles: ["System"], bytes: 50, device: "disk3s1"),
        ], dataDevice: "disk3s5")
    let value = try #require(ScanStorageAccounting(scan: accountingScan(), capacity: accountingCapacity(), apfs: apfs))
    #expect(value.apfs?.dataBytes == 800)
    #expect(ScanStorageAccounting(scan: accountingScan(), capacity: nil, apfs: apfs)?.capacity.used == 853)
    #expect(value.measuredBreakdown?.contains("Data not yet attributed to files") == true)
    #expect(value.measuredBreakdown?.contains("System (System)") == true)
    #expect(value.measuredBreakdown?.contains("APFS pool accounting adjustment") == true)
    let systemScan = try #require(ScanStorageAccounting(scan: accountingScan(path: "/"), capacity: accountingCapacity(), apfs: apfs))
    #expect(systemScan.apfs == nil)
}

@Test func scanAccountingUnreadableFolderSizeIsUnknownRatherThanZero() {
    var node = DiskNode(id: 1, parent: 0, name: "Group Containers", isDirectory: true)
    node.isContentsUnreadable = true
    #expect(StorageLabels.size(node, allocated: true) == "Not scanned · unreadable")
    #expect(StorageLabels.size(node, allocated: false) == "Not scanned · unreadable")
    #expect(StorageLabels.size(node, allocated: true, compact: true) == "Not scanned")
    node.isContentsUnreadable = false
    #expect(StorageLabels.size(node, allocated: true) == DiskFormat.bytes(0))
    node.isScanIncomplete = true
    #expect(StorageLabels.size(node, allocated: true) == "Size unknown · incomplete scan")
    #expect(StorageLabels.size(node, allocated: true, compact: true) == "Size unknown")
    node.allocatedBytes = 10_000
    #expect(StorageLabels.size(node, allocated: true).contains("scanned · incomplete"))
    #expect(StorageLabels.size(node, allocated: true, compact: true) == "\(DiskFormat.bytes(10_000)) scanned")
}

@Test func scanAccountingDoesNotCompareUnrelatedFolderOrDiskWithStartupCapacity() {
    for path in ["/Users/example", "/Volumes/External", "/System/Volumes/Data/Users"] {
        #expect(ScanStorageAccounting(scan: accountingScan(path: path), capacity: accountingCapacity()) == nil)
    }
    #expect(ScanStorageAccounting(scan: accountingScan(), capacity: nil) == nil)
    #expect(ScanStorageAccounting(scan: ScanResult(rootPath: "/", nodes: []), capacity: accountingCapacity()) == nil)
}

@Test func scanAccountingKeepsSharedAllocationExcessVisible() throws {
    let value = try #require(ScanStorageAccounting(scan: accountingScan(bytes: 1_100), capacity: accountingCapacity()))
    #expect(value.exceedsUsed)
    #expect(value.scanned == 1_100)
    #expect(value.outsideBreakdown == 0)
    #expect(value.explanation.contains("cannot be reconciled"))
    #expect(!value.summary.contains("used outside this breakdown"))
    #expect(value.summary.hasPrefix("\(DiskFormat.bytes(value.capacity.used)) used of \(DiskFormat.bytes(value.capacity.total)) startup storage"))
    #expect(value.summary.contains("file allocations (shared blocks can count more than once)"))
}

@Test func scanCoverageDoesNotPresentBoundedEvidenceAsCompleteCountsOrSizes() {
    var scan = accountingScan()
    scan.skipped = 1_405
    scan.incompleteEvidence = [
        ScanIncompleteEvidence(path: "/omitted/a", reason: "unreadable directory"),
        ScanIncompleteEvidence(path: "/omitted/b", reason: "excluded by folder settings"),
        ScanIncompleteEvidence(path: "/omitted/c", reason: "unreadable directory"),
    ]
    scan.incompleteEvidenceTruncated = true
    #expect(scan.coverageExplanation.contains("unreadable directory: 2 entries"))
    #expect(scan.coverageExplanation.contains("does not list every skipped entry"))
    #expect(scan.coverageExplanation.contains("not a file count or a measurement of missing bytes"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_LIVE_SCAN_EVIDENCE"] == "1"))
@MainActor func liveScanAccountingNativeFixtures() async throws {
    let model = ExplorerModel()
    model.liveStorageCapacity = StartupCapacity(total: 1_000_000_000_000, available: 58_000_000_000)
    let progress = ScanProgress(entries: 13_769_069, path: "/System/Volumes/Data", allocatedBytes: 1_230_000_000_000,
        files: 13_000_000, skipped: 6_193, elapsed: 145, locations: [
            ScanLiveLocation(id: 1, name: "private", allocatedBytes: 700_000_000_000),
            ScanLiveLocation(id: 2, name: "Users", allocatedBytes: 480_000_000_000),
            ScanLiveLocation(id: 3, name: "Applications", allocatedBytes: 50_000_000_000),
        ])
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".fleet-local/live-scan-capacity")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scan = ScanResult(rootPath: "/synthetic/com.google.Chrome.code_sign_clone", nodes: [
        DiskNode(id: 0, parent: nil, name: "com.google.Chrome.code_sign_clone", isDirectory: true,
            allocatedBytes: 474_630_000_000, children: [1]),
        DiskNode(id: 1, parent: 0, name: "code_sign_clone.example", isDirectory: true,
            allocatedBytes: 474_630_000_000),
    ])
    model.scan = scan; model.volumeFree = 58_000_000_000; model.volumeCapacity = 1_000_000_000_000
    model.liveProgress = progress; model.progress = "Synthetic display fixture · No filesystem scan"
    model.refreshFocus()
    for (state, width) in ["live", "folder"].flatMap({ state in [880, 1200, 1440].map { (state, $0) } }) {
        model.busy = state == "live"
        let host = NSHostingView(rootView: ExplorerView(runsLaunchActions: false).environmentObject(model)
            .preferredColorScheme(.dark).frame(width: CGFloat(width), height: 900))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(state)-\(width).png"))
    }
}
