import Foundation

public struct DuplicateSurvivorSelection: Sendable {
    public let members: Set<Int>
    public let kept: Set<Int>
    public init(members: Set<Int>, kept: Set<Int>) { self.members = members; self.kept = kept }
}

public enum DuplicateSurvivorProtection {
    /// Includes coverage by staged ancestor folders, not just direct file IDs.
    public static func validateCoverage(scan: ScanResult, selections: [DuplicateSurvivorSelection], staged: Set<Int>) throws {
        for selection in selections {
            guard !selection.kept.isEmpty, selection.kept.isSubset(of: selection.members),
                  selection.members.allSatisfy({ scan.nodes.indices.contains($0) && !scan.nodes[$0].isDirectory && !scan.nodes[$0].isSymlink }) else { throw changed() }
            for id in selection.kept {
                var current: Int? = id
                while let next = current {
                    guard scan.nodes.indices.contains(next), !staged.contains(next) else { throw changed() }
                    let parent = scan.nodes[next].parent
                    guard parent == nil || (parent! >= 0 && parent! < next) else { throw changed() }
                    current = parent
                }
            }
        }
    }
    public static func validateSurvivors(scan: ScanResult, selections: [DuplicateSurvivorSelection], staged: Set<Int>,
        verify: (URL, DiskNode, URL) throws -> Void = CleanupSafety.validate) throws {
        try validateCoverage(scan: scan, selections: selections, staged: staged)
        let root = URL(fileURLWithPath: scan.rootPath)
        for id in Set(selections.flatMap { $0.kept }) {
            try Task.checkCancellation()
            try verify(scan.url(for: id), scan.nodes[id], root)
        }
    }
    private static func changed() -> NSError {
        NSError(domain: "DuplicateReview", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "A kept duplicate is staged, covered by a staged folder, missing or changed. Review Duplicates and Cleanup again."])
    }
}
