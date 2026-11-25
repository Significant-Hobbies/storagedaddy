import AgentBridge
import Darwin
import DiskCore
import Foundation

/// A read-only plan bound to the scan whose node IDs the owner will review.
struct AgentSpacePlan {
    let id = UUID()
    let percent: Int
    let baseline: StartupCapacity
    let root: String?
    let scanIdentity: UUID
    private let choices: [(id: Int, row: AgentJSON)]
    var nodeIDs: Set<Int> { Set(choices.map(\.id)) }

    @MainActor init(percent: Int, baseline: StartupCapacity, explorer: ExplorerModel) {
        self.percent = percent
        self.baseline = baseline
        let scan = explorer.scan
        root = scan?.rootPath
        scanIdentity = explorer.filenameSearchIdentity
        var disk = stat()
        guard !explorer.scanIsHistorical, !explorer.isScanning, !explorer.exclusionResultsStale, let scan,
              stat("/System/Volumes/Data", &disk) == 0 else { choices = []; return }
        let device = UInt64(UInt32(bitPattern: disk.st_dev))
        let exclusions = FolderExclusions(paths: explorer.excludedFolders)
        var categories: [Int: DeveloperCategory] = [:]
        for group in explorer.developerGroups where [.nodeModules, .buildOutputs, .packageCaches].contains(group.category) {
            for nodeID in group.rootIDs { categories[nodeID] = group.category }
        }
        let ids = Set(explorer.quickWinNodes.map(\.id)).union(categories.keys)
        var candidates: [DiskNode] = []
        for id in ids where scan.nodes.indices.contains(id) {
            let node = scan.nodes[id]
            if node.parent != nil, node.device == device, node.allocatedBytes > 0,
               !node.isSymlink, node.isScanIncomplete != true { candidates.append(node) }
        }
        candidates.sort { a, b in
            if a.allocatedBytes == b.allocatedBytes { return a.id < b.id }
            return a.allocatedBytes > b.allocatedBytes
        }
        var rows: [(Int, AgentJSON)] = []
        var selectedPaths: [String] = []
        for node in candidates {
            let url = scan.url(for: node.id)
            guard !exclusions.blocksCleanup(url), !selectedPaths.contains(where: { url.path.hasPrefix($0 + "/") || $0.hasPrefix(url.path + "/") }),
                  CleanupGuidance.requiredNativeCleaner(path: url.path) == nil else { continue }
            rows.append((node.id, .object(["nodeID": .integer(node.id), "path": .string(url.path),
                "attributedBytes": .integer(node.allocatedBytes), "consequence": .string(CleanupGuidance.explanation(for: categories[node.id]))])))
            selectedPaths.append(url.path)
            if rows.count == 20 { break }
        }
        choices = rows
    }

    func reading(_ capacity: StartupCapacity) -> AgentJSON {
        // floor(total * percent / 100) without overflowing the multiplication.
        let allowedUsed = capacity.total / 100 * Int64(percent) + capacity.total % 100 * Int64(percent) / 100
        let needed = max(0, capacity.used - allowedUsed)
        return .object(["planID": .string(id.uuidString), "targetUsedPercent": .integer(percent),
            "capacityBytes": .integer(capacity.total), "baselineFreeBytes": .integer(baseline.available),
            "freeBytes": .integer(capacity.available), "additionalFreeBytesNeeded": .integer(needed),
            "targetReached": .bool(needed == 0), "observedFreeBytesChange": .integer(capacity.available - baseline.available)])
    }

    var proposal: AgentJSON {
        var fields = reading(baseline).object ?? [:]
        fields["scanRoot"] = root.map(AgentJSON.string) ?? .null
        fields["choices"] = .array(choices.map(\.row))
        fields["guidance"] = .string("Choices cover the current scan on the startup data volume. Measure the selected items together. Native review checks each removal. Disk free-space changes also include other activity.")
        return .object(fields)
    }
}
