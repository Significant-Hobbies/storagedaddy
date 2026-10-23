import Foundation

public enum SnapshotArchive {
    /// Comparison needs top-level totals, not a second copy of a million-file tree.
    public static func compact(_ scan: ScanResult) -> ScanResult {
        guard var root = scan.nodes.first else { return scan }
        var nodes = [root]
        for child in root.children where scan.nodes.indices.contains(child) {
            var n = scan.nodes[child]; n.id = nodes.count; n.parent = 0; n.children = []; nodes.append(n)
        }
        root.children = Array(nodes.indices.dropFirst()); nodes[0] = root
        return ScanResult(rootPath: scan.rootPath, nodes: nodes, started: scan.started, elapsed: scan.elapsed, processDiskReadBytes: scan.processDiskReadBytes, errors: scan.errors, skipped: scan.skipped, incompleteEvidence: scan.incompleteEvidence, incompleteEvidenceTruncated: scan.incompleteEvidenceTruncated)
    }
    public static func read(_ url: URL) throws -> ScanResult {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw invalid("Snapshot exceeds the 64 MB import limit.") }
        let value = try JSONDecoder().decode(ScanResult.self, from: Data(contentsOf: url))
        try validate(value)
        return compact(value)
    }
    public static func validate(_ value: ScanResult, maximumNodes: Int = 999_999) throws {
        guard value.rootPath.hasPrefix("/"), !value.nodes.isEmpty, value.nodes.count <= min(2_000_000, maximumNodes) else { throw invalid("Invalid snapshot root or item count.") }
        var referenced = Set<Int>()
        for (i, n) in value.nodes.enumerated() {
            guard n.id == i, n.logicalBytes >= 0, n.allocatedBytes >= 0, !n.name.isEmpty,
                  i == 0 || (!n.name.contains("/") && n.name != "." && n.name != ".."),
                  i == 0 ? n.parent == nil : (n.parent != nil && n.parent! >= 0 && n.parent! < i),
                  Set(n.children).count == n.children.count,
                  n.children.allSatisfy({ $0 > i && $0 < value.nodes.count && value.nodes[$0].parent == i }) else { throw invalid("Invalid snapshot item or hierarchy.") }
            let names = n.children.map { value.nodes[$0].name }
            guard Set(names).count == names.count else { throw invalid("Snapshot contains duplicate names.") }
            referenced.formUnion(n.children)
        }
        guard referenced.count == value.nodes.count - 1 else { throw invalid("Snapshot contains an orphaned item.") }
        var measured = Set<Int>()
        for detail in value.fileAllocationDetails ?? [] {
            guard value.nodes.indices.contains(detail.nodeID), measured.insert(detail.nodeID).inserted,
                  !value.nodes[detail.nodeID].isDirectory, !value.nodes[detail.nodeID].isSymlink,
                  detail.reportedBytes >= 0, detail.linkCount > 0,
                  detail.privateBytes.map({ $0 >= 0 && $0 <= detail.reportedBytes }) ?? true else {
                throw invalid("Snapshot contains invalid file-allocation metadata.")
            }
        }
    }
    private static func invalid(_ text: String) -> NSError { NSError(domain: "Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
