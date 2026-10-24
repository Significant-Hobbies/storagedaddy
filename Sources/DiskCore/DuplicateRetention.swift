import Foundation

public enum DuplicateRetention {
    /// Deterministic date ties retain the lexically first path. Selection only;
    /// the normal content/survivor preflight still runs before any cleanup.
    public static func removals(in groups: [DuplicateGroup], scan: ScanResult, keepNewest: Bool) -> [Int] {
        groups.flatMap { group -> [Int] in
            guard group.nodeIDs.count > 1, Set(group.nodeIDs).count == group.nodeIDs.count,
                  group.nodeIDs.allSatisfy({ scan.nodes.indices.contains($0) && !scan.nodes[$0].isDirectory && !scan.nodes[$0].isSymlink && scan.nodes[$0].parent != nil }) else { return [] }
            let sorted = group.nodeIDs.sorted { lhs, rhs in
                let left = scan.nodes[lhs], right = scan.nodes[rhs]
                if left.modified != right.modified { return keepNewest ? left.modified > right.modified : left.modified < right.modified }
                return scan.url(for: lhs).path < scan.url(for: rhs).path
            }
            return Array(sorted.dropFirst())
        }
    }
}
