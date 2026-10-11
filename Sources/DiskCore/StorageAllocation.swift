import Foundation

public struct FileAllocationDetail: Codable, Sendable, Equatable {
    public var nodeID: Int
    public let reportedBytes: Int64
    public let privateBytes: Int64?
    public let sharesStorage: Bool
    public let linkCount: UInt32

    public init(nodeID: Int, reportedBytes: Int64, privateBytes: Int64?, sharesStorage: Bool, linkCount: UInt32) {
        self.nodeID = nodeID; self.reportedBytes = reportedBytes; self.privateBytes = privateBytes
        self.sharesStorage = sharesStorage; self.linkCount = linkCount
    }
}

public struct StorageAllocationSummary: Sendable {
    public let exclusiveBytes: Int64?
    public let sharedFiles: Int
    public let isIncomplete: Bool
}

/// Index only the files with sharing, hard links or missing private-byte metadata,
/// and their ancestors. Unshared files need no extra retained record.
public struct StorageAllocationIndex: Sendable {
    private struct Adjustment: Sendable {
        var attributed: Int64 = 0
        var exclusive: Int64 = 0
        var sharedFiles = 0
        var unknown = false
    }
    private var adjustments: [Int: Adjustment] = [:]
    private let recorded: Bool

    public init(scan: ScanResult) { self.init(scan: scan, cancellationCheck: {}) }

    public init(scan: ScanResult, cancellationCheck: () throws -> Void) rethrows {
        recorded = scan.fileAllocationDetails != nil
        for (index, detail) in (scan.fileAllocationDetails ?? []).enumerated() {
            if index & 255 == 0 { try cancellationCheck() }
            guard scan.nodes.indices.contains(detail.nodeID) else { continue }
            let file = scan.nodes[detail.nodeID]
            var current: Int? = detail.nodeID
            while let id = current, scan.nodes.indices.contains(id) {
                var value = adjustments[id] ?? Adjustment()
                value.attributed = adding(value.attributed, file.allocatedBytes)
                // A hard link can remain outside the scan or cleanup selection.
                // Exclude its bytes from the conservative exclusive estimate.
                if detail.linkCount <= 1, let bytes = detail.privateBytes {
                    value.exclusive = adding(value.exclusive, min(detail.reportedBytes, max(0, bytes)))
                }
                value.unknown = value.unknown || detail.privateBytes == nil
                if detail.sharesStorage { value.sharedFiles += 1 }
                adjustments[id] = value
                guard let parent = scan.nodes[id].parent, parent < id else { break }
                current = parent
            }
        }
    }

    public func summary(for node: DiskNode) -> StorageAllocationSummary {
        let value = adjustments[node.id] ?? Adjustment()
        let incomplete = node.isScanIncomplete == true || node.isContentsUnreadable == true
        let exclusive = recorded && !value.unknown && !incomplete
            ? adding(max(0, node.allocatedBytes - value.attributed), value.exclusive) : nil
        return StorageAllocationSummary(exclusiveBytes: exclusive, sharedFiles: value.sharedFiles, isIncomplete: incomplete)
    }
}

private func adding(_ left: Int64, _ right: Int64) -> Int64 {
    let (sum, overflow) = left.addingReportingOverflow(max(0, right))
    return overflow ? .max : sum
}
