import Foundation

/// Read only the index entries within the classified artifact roots. A missing
/// path, truncated result, failed command or canceled scan never means untracked.
public enum ProjectGitTrackingProbe {
    public static func collect(scan: ScanResult, projectID: Int, artifactIDs: [Int],
        run: (URL, [String]) -> String? = GitCheckoutProbe.runLocal) throws -> ProjectPurgeGitEvidence {
        try Task.checkCancellation()
        guard scan.nodes.indices.contains(projectID), scan.nodes[projectID].isDirectory,
              !scan.nodes[projectID].isSymlink else { return .unavailable }
        func relativePath(_ id: Int) -> String? {
            guard scan.nodes.indices.contains(id), id != projectID else { return nil }
            var current = id, names: [String] = []
            while current != projectID {
                let node = scan.nodes[current]
                guard !node.name.isEmpty, ![".", ".."].contains(node.name), !node.name.contains("/"),
                      let parent = node.parent, parent >= 0, parent < current else { return nil }
                names.append(node.name); current = parent
            }
            return names.reversed().joined(separator: "/")
        }
        let paths = artifactIDs.compactMap(relativePath)
        guard paths.count == artifactIDs.count, !paths.isEmpty else { return .unavailable }
        let directory = scan.url(for: projectID)
        guard run(directory, ["rev-parse", "--is-inside-work-tree"])?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .unavailable
        }
        try Task.checkCancellation()
        guard let output = run(directory, ["ls-files", "--cached", "-z", "--"] + paths),
              output.isEmpty || output.last == "\0" else {
            return .failed("Git index entries could not be fully read.")
        }
        var children: [Int: [String: Int]] = [:]
        var tracked = Set<Int>()
        for path in output.split(separator: "\0", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            // The index may include entries missing from this filesystem scan.
            // Such entries protect the entire proposal rather than disappear.
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            var current = projectID
            for part in parts {
                guard !part.isEmpty, part != ".", part != ".." else { return .failed("Git returned an invalid path.") }
                if children[current] == nil {
                    var byName: [String: Int] = [:]
                    for id in scan.nodes[current].children {
                        guard scan.nodes.indices.contains(id), scan.nodes[id].parent == current,
                              byName.updateValue(id, forKey: scan.nodes[id].name) == nil else {
                            return .failed("Scan paths could not be uniquely matched to the index.")
                        }
                    }
                    children[current] = byName
                }
                guard let id = children[current]?[String(part)] else {
                    return .failed("A Git-tracked path is absent from this scan.")
                }
                current = id
            }
            guard paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                return .failed("Git returned a path outside the requested artifacts.")
            }
            tracked.insert(current)
        }
        return .verified(trackedNodeIDs: tracked, checkoutRootIDs: [projectID])
    }
}
