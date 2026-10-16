import Foundation

public enum CleanupPreflightError: Error, LocalizedError, Sendable {
    case excludedFolder(String)
    case invalidNodeID(Int)
    case rootNode(Int)
    case overlappingNodes(Int, Int)
    case incompleteRescan(path: String, review: CleanupIncompleteReview)
    case missingRecord(path: String)
    case changedRecord(path: String)

    public var errorDescription: String? {
        switch self {
        case let .excludedFolder(path):
            return "\(URL(fileURLWithPath: path).lastPathComponent) is excluded or contains an excluded folder. Remove the exclusion in Settings before reviewing cleanup again."
        case let .invalidNodeID(id):
            return "Cleanup candidate \(id) is not present in the scan."
        case let .rootNode(id):
            return "The scan root (node \(id)) cannot be staged for cleanup."
        case let .overlappingNodes(first, second):
            return "Cleanup candidates \(first) and \(second) overlap. Select only one parent path."
        case let .incompleteRescan(path, review):
            return "\(URL(fileURLWithPath: path).lastPathComponent) contains \(review.skipped) excluded or unreadable \(review.skipped == 1 ? "item" : "items"). Review the skipped locations before continuing."
        case let .missingRecord(path):
            return "The cleanup candidate changed: missing \(path)."
        case let .changedRecord(path):
            return "The cleanup candidate changed: \(path)."
        }
    }
}

public enum CleanupPreflight {
    public static func validate(ids: [Int], in scan: ScanResult, acknowledgedIncomplete: [Int: CleanupIncompleteReview] = [:], excludedFolders: [String] = [],
                                regenerableIDs: Set<Int> = [], home: String = FileManager.default.homeDirectoryForCurrentUser.path) async throws {
        try Task.checkCancellation()
        guard !ids.isEmpty else { return }

        var selected = Set<Int>()
        var candidates: [DiskNode] = []
        candidates.reserveCapacity(ids.count)
        for id in ids {
            guard scan.nodes.indices.contains(id), scan.nodes[id].id == id else {
                throw CleanupPreflightError.invalidNodeID(id)
            }
            guard selected.insert(id).inserted else {
                throw CleanupPreflightError.overlappingNodes(id, id)
            }
            let node = scan.nodes[id]
            guard node.parent != nil else {
                throw CleanupPreflightError.rootNode(id)
            }
            candidates.append(node)
        }

        let rootURL = URL(fileURLWithPath: scan.rootPath).standardizedFileURL
        let candidateURLs = candidates.map { (node: $0, url: scan.url(for: $0.id).standardizedFileURL) }
        for firstIndex in candidateURLs.indices {
            for secondIndex in candidateURLs.indices where secondIndex > firstIndex {
                let firstPath = candidateURLs[firstIndex].url.path
                let secondPath = candidateURLs[secondIndex].url.path
                if isDescendant(firstPath, of: secondPath) || isDescendant(secondPath, of: firstPath) {
                    throw CleanupPreflightError.overlappingNodes(
                        candidateURLs[firstIndex].node.id,
                        candidateURLs[secondIndex].node.id
                    )
                }
            }
        }

        let exclusions = FolderExclusions(paths: excludedFolders)
        for candidate in candidateURLs where exclusions.blocksCleanup(candidate.url) {
            throw CleanupPreflightError.excludedFolder(candidate.url.path)
        }

        let regenerable = Set(candidateURLs.filter {
            regenerableIDs.contains($0.node.id) && $0.node.isDirectory
                && CleanupGuidance.isRegenerableFolder(path: $0.url.path, home: home)
        }.map { $0.node.id })
        let dependencies = Set(candidateURLs.filter {
            regenerable.contains($0.node.id) && CleanupGuidance.isProjectDependencies(path: $0.url.path)
        }.map { $0.node.id })

        // Reject protected paths and stale identities before traversing candidates.
        for candidate in candidates {
            try CleanupSafety.validate(url: scan.url(for: candidate.id), expected: candidate, root: rootURL,
                                       allowingRegenerableChanges: regenerable.contains(candidate.id), home: home)
        }

        // Reinstallable project dependencies are reviewed as a whole folder.
        // Keep root identity/path checks without walking every package again.
        for candidate in candidateURLs where candidate.node.isDirectory && !dependencies.contains(candidate.node.id) {
            try Task.checkCancellation()

            let result = try await DiskScanner.scan(root: candidate.url)
            // Broad parent selections must not bypass signing-copy checks.
            for node in result.nodes where node.isDirectory && node.name == "com.google.Chrome.code_sign_clone" {
                try ChromeSigningClones.validateForCleanup(at: result.url(for: node.id))
            }
            if !regenerable.contains(candidate.node.id) {
                let before = try records(in: scan, rootID: candidate.node.id)
                let after = try records(in: result, rootID: 0)
                try compare(before: before, after: after)
            }
            if result.skipped > 0, ChromeSigningClones.location(path: candidate.url.path) == .copy {
                throw NSError(domain: "ChromeSigningCopies", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The signing copy could not be checked completely. Keep it and rescan after resolving unreadable or excluded contents."])
            }

            if result.skipped > 0 {
                let rawEvidence = result.incompleteEvidence ?? []
                let hasUnknownEvidence = result.incompleteEvidenceTruncated == true || rawEvidence.count != result.skipped
                let evidence = hasUnknownEvidence
                    ? rawEvidence + [ScanIncompleteEvidence(path: candidate.url.path, reason: "unknown evidence (truncated)")]
                    : rawEvidence
                let review = CleanupIncompleteReview(
                    skipped: result.skipped,
                    evidence: evidence,
                    truncated: hasUnknownEvidence,
                    root: URL(fileURLWithPath: result.rootPath),
                    device: candidate.node.device,
                    inode: candidate.node.inode
                )
                guard review.canAcknowledge, acknowledgedIncomplete[candidate.node.id] == review else {
                    throw CleanupPreflightError.incompleteRescan(path: candidate.url.path, review: review)
                }
            }
        }

        let checkedForUse = regenerable.subtracting(dependencies)
        if !checkedForUse.isEmpty {
            let urls = candidateURLs.filter { checkedForUse.contains($0.node.id) }.map(\.url)
            let probe = Task.detached(priority: .utility) { try CleanupActiveUse.validate(urls: urls) }
            try await probe.value
        }

        // Run the final identity/path checks after all subtree comparisons. This
        // detects stale scan identities. Path-based moves still have a small
        // validation-to-use window and are not an atomic filesystem transaction.
        for candidate in candidates {
            try Task.checkCancellation()
            try CleanupSafety.validate(
                url: scan.url(for: candidate.id),
                expected: candidate,
                root: rootURL,
                allowingRegenerableChanges: regenerable.contains(candidate.id), home: home
            )
        }
    }

    private struct Record: Equatable {
        let isDirectory: Bool
        let isSymlink: Bool
        let logicalBytes: Int64
        let modified: Date
        let device: UInt64
        let inode: UInt64

        init(_ node: DiskNode) {
            isDirectory = node.isDirectory
            isSymlink = node.isSymlink
            logicalBytes = node.logicalBytes
            modified = node.modified
            device = node.device
            inode = node.inode
        }

        func matches(_ other: Record) -> Bool {
            guard isDirectory == other.isDirectory,
                  isSymlink == other.isSymlink,
                  modified == other.modified,
                  device == other.device,
                  inode == other.inode else { return false }
            if isDirectory {
                // Directory byte totals are derived, not directory metadata.
                // Hard links and full clones may be charged outside this subtree in the full
                // scan, then inside it during preflight. Every known descendant
                // is compared separately below, including file sizes/identities.
                return true
            }
            return logicalBytes == other.logicalBytes
        }
    }

    // Visit only the selected subtree, not every node in a whole-disk scan.
    private static func records(in scan: ScanResult, rootID: Int) throws -> [String: Record] {
        var records: [String: Record] = [:]
        var pending: [(Int, String)] = [(rootID, "")]
        while let (id, relative) = pending.popLast() {
            try Task.checkCancellation()
            guard scan.nodes.indices.contains(id) else { throw CleanupPreflightError.invalidNodeID(id) }
            let node = scan.nodes[id]
            guard records.updateValue(Record(node), forKey: relative) == nil else {
                throw CleanupPreflightError.changedRecord(path: relative)
            }
            for child in node.children {
                guard scan.nodes.indices.contains(child) else { throw CleanupPreflightError.invalidNodeID(child) }
                let name = scan.nodes[child].name
                pending.append((child, relative.isEmpty ? name : relative + "/" + name))
            }
        }
        return records
    }

    private static func compare(before: [String: Record], after: [String: Record]) throws {
        let beforePaths = Set(before.keys)
        let afterPaths = Set(after.keys)
        guard beforePaths == afterPaths else {
            if let missing = beforePaths.subtracting(afterPaths).sorted().first {
                throw CleanupPreflightError.missingRecord(path: missing.isEmpty ? "." : missing)
            }
            if let added = afterPaths.subtracting(beforePaths).sorted().first {
                throw CleanupPreflightError.changedRecord(path: added.isEmpty ? "." : added)
            }
            throw CleanupPreflightError.changedRecord(path: ".")
        }
        for path in beforePaths {
            guard let oldRecord = before[path], let newRecord = after[path], oldRecord.matches(newRecord) else {
                throw CleanupPreflightError.changedRecord(path: path.isEmpty ? "." : path)
            }
        }
    }

    private static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        guard path != ancestor else { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
