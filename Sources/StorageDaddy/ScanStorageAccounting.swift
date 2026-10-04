import Foundation
import DiskCore

/// A comparison of file allocations with the startup pool's capacity estimate.
/// The difference is unclassified occupied space, never free space or a
/// measurement of any individual skipped folder.
struct ScanStorageAccounting: Sendable {
    let capacity: StartupCapacity
    let scanned: Int64
    let apfs: StartupAPFSAccounting?

    init?(scan: ScanResult, capacity: StartupCapacity?, apfs: StartupAPFSAccounting? = nil) {
        guard ["/", "/System/Volumes/Data"].contains(scan.rootPath),
              let root = scan.nodes.first, root.allocatedBytes >= 0 else { return nil }
        let matchedAPFS = scan.rootPath == "/System/Volumes/Data" ? apfs : nil
        guard let capacity = matchedAPFS.flatMap({ StartupCapacity(total: $0.total, available: $0.available) }) ?? capacity else { return nil }
        self.apfs = matchedAPFS
        self.capacity = capacity
        scanned = root.allocatedBytes
    }

    var outsideBreakdown: Int64 { max(0, capacity.used - scanned) }
    var exceedsUsed: Bool { scanned > capacity.used }

    var measuredBreakdown: String? {
        guard let apfs else { return nil }
        var lines = ["Measured startup storage allocation (\(apfs.measuredAt.formatted(date: .abbreviated, time: .shortened))):",
                     "Data volume: \(DiskFormat.bytes(apfs.dataBytes)) occupied; \(DiskFormat.bytes(scanned)) in scanned file allocations."]
        if scanned <= apfs.dataBytes {
            lines.append("Data not yet attributed to files: \(DiskFormat.bytes(apfs.dataBytes - scanned)). Protected/excluded locations and Data filesystem accounting need further inspection; this is not a measured category of junk or free space.")
        } else {
            lines.append("Scanned file allocations exceed the Data volume's physical allocation. Shared blocks or changing measurements prevent an additive file breakdown.")
        }
        lines += apfs.otherVolumes.map { "\($0.name) (\($0.roles.isEmpty ? "other volume" : $0.roles.joined(separator: ", "))): \(DiskFormat.bytes($0.bytes))." }
        lines.append("APFS pool accounting adjustment: \(apfs.poolAdjustment < 0 ? "−" : "+")\(DiskFormat.bytes(abs(apfs.poolAdjustment))). This is the difference between pool usage and summed volume allocations, not a measured folder or proven snapshot size.")
        lines.append("Total used: \(DiskFormat.bytes(apfs.used)). Available: \(DiskFormat.bytes(apfs.available)). Pool capacity: \(DiskFormat.bytes(apfs.total)).")
        return lines.joined(separator: "\n")
    }

    var summary: String {
        if exceedsUsed {
            return "\(DiskFormat.bytes(scanned)) scanned · \(DiskFormat.bytes(capacity.used)) used across startup storage · \(DiskFormat.bytes(capacity.available)) available"
        }
        return "\(DiskFormat.bytes(scanned)) scanned · \(DiskFormat.bytes(outsideBreakdown)) used outside this breakdown · \(DiskFormat.bytes(capacity.available)) available"
    }

    var explanation: String {
        let comparison = exceedsUsed
            ? "File allocations exceed the startup storage estimate. APFS files can share blocks, and storage can change between measurements; these figures cannot be reconciled as separate physical allocations."
            : "macOS reports \(DiskFormat.bytes(capacity.used)) used across \(DiskFormat.bytes(capacity.total)) of startup storage. This scan accounts for \(DiskFormat.bytes(scanned)) in file allocations. The remaining \(DiskFormat.bytes(outsideBreakdown)) is used space outside this breakdown, not unused space."
        return comparison + "\n\nThe file scan cannot enumerate everything counted by macOS: protected or unreadable folders, exclusions, and separate APFS system volumes are outside its coverage. Snapshots and filesystem metadata can also occupy space without appearing as ordinary files. The difference is an estimate, not a measured size for any one of these causes. Shared APFS blocks and changes since the scan also affect the comparison.\n\nOnly \(DiskFormat.bytes(capacity.available)) is reported as available. Purgeable space is part of used space that macOS may reclaim; do not add it to the breakdown again. Use Scan Folder to include a specific omitted folder, or optionally grant Full Disk Access and rescan for broader coverage. Snapshot blocks and filesystem metadata have no ordinary folder tree to expand here."
    }
}

extension ScanResult {
    var coverageExplanation: String {
        var sections = ["\(skipped.formatted()) entries were skipped. A skipped directory can contain many files, so this count is not a file count or a measurement of missing bytes. Totals include only scanned file allocations."]
        let evidence = incompleteEvidence ?? []
        if !evidence.isEmpty {
            sections.append("Recorded reasons (bounded sample):\n" + Dictionary(grouping: evidence, by: \.reason)
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.count.formatted()) entries" }.joined(separator: "\n"))
            let examples = evidence.filter { $0.reason != "excluded by sensitive path policy" }
                .sorted { ($0.path.split(separator: "/").count, $0.path) < ($1.path.split(separator: "/").count, $1.path) }
                .prefix(16)
            if !examples.isEmpty {
                sections.append("Omitted location examples (sizes unmeasured):\n" + examples.map {
                    "\(StorageLabels.location($0.path)): \($0.reason)"
                }.joined(separator: "\n"))
            }
        }
        if incompleteEvidenceTruncated == true || evidence.count < skipped {
            sections.append("The retained evidence does not list every skipped entry; the counts above are only recorded examples.")
        }
        sections.append("Automatic scans skip Desktop, Documents, Downloads, Movies, Music and Pictures when protected-folder access is limited or unknown, to avoid repeated macOS permission prompts. Sensitive paths and excluded folders are also omitted; scans stop at mount boundaries and never follow symlink targets. Use Scan Folder to include a specific protected folder, or optionally enable Full Disk Access and rescan. Broader access does not include separate volumes or override exclusions.")
        return sections.joined(separator: "\n\n")
    }
}
