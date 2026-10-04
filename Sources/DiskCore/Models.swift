import Foundation

public struct DiskNode: Codable, Sendable, Identifiable {
    public var id: Int
    public var parent: Int?
    // Pack flags into the optional parent's alignment padding. This keeps the
    // same public/Codable fields while saving eight bytes per node on arm64.
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// nil for legacy scans or before traversal; true means contents could
    /// not be enumerated. An unreadable directory is not an empty directory.
    public var isContentsUnreadable: Bool? = nil
    /// Includes omissions in descendants. Optional for legacy scan decoding.
    public var isScanIncomplete: Bool? = nil
    public var name: String
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var modified: Date
    public var device: UInt64
    public var inode: UInt64
    public var children: [Int]
    public init(id: Int, parent: Int?, name: String, isDirectory: Bool, isSymlink: Bool = false, logicalBytes: Int64 = 0, allocatedBytes: Int64 = 0, modified: Date = .distantPast, device: UInt64 = 0, inode: UInt64 = 0, children: [Int] = []) {
        self.id = id; self.parent = parent; self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.modified = modified; self.device = device; self.inode = inode; self.children = children
    }
}
public struct ScanResult: Codable, Sendable {
    public var rootPath: String
    public var nodes: [DiskNode]
    public var started: Date
    public var elapsed: Double
    /// Bytes macOS charged to this process's disk-read counter during the scan.
    /// Optional to preserve decoding of snapshots written before this field existed.
    public var processDiskReadBytes: UInt64?
    public var errors: [String]
    public var skipped: Int
    /// Bounded metadata-only evidence for entries omitted from the scan.
    /// Optional to preserve decoding of snapshots written before this field existed.
    public var incompleteEvidence: [ScanIncompleteEvidence]?
    public var incompleteEvidenceTruncated: Bool?
    public init(rootPath: String, nodes: [DiskNode], started: Date = Date(), elapsed: Double = 0, processDiskReadBytes: UInt64? = nil, errors: [String] = [], skipped: Int = 0, incompleteEvidence: [ScanIncompleteEvidence]? = nil, incompleteEvidenceTruncated: Bool? = nil) {
        self.rootPath = rootPath; self.nodes = nodes; self.started = started; self.elapsed = elapsed; self.errors = errors; self.skipped = skipped; self.incompleteEvidence = incompleteEvidence; self.incompleteEvidenceTruncated = incompleteEvidenceTruncated
        self.processDiskReadBytes = processDiskReadBytes
    }
    public func url(for id: Int) -> URL {
        var parts: [String] = []; var current = id
        while current > 0, nodes.indices.contains(current) { parts.append(nodes[current].name); current = nodes[current].parent ?? 0 }
        return parts.reversed().reduce(URL(fileURLWithPath: rootPath)) { $0.appendingPathComponent($1) }
    }
    public var fileCount: Int { nodes.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) } }
}

public struct ScanIncompleteEvidence: Codable, Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// The exact bounded evidence a user reviewed before allowing an incomplete
/// folder cleanup to proceed.
public struct CleanupIncompleteReview: Sendable, Equatable {
    public let skipped: Int
    public let details: [String]
    public let canAcknowledge: Bool
    private let evidenceRootPath: String
    private let evidence: [ScanIncompleteEvidence]
    private let device: UInt64
    private let inode: UInt64

    public init(skipped: Int, details: [String]) {
        self.skipped = skipped
        self.details = details
        self.canAcknowledge = false
        self.evidenceRootPath = ""
        self.evidence = []
        self.device = 0
        self.inode = 0
    }

    init(skipped: Int, evidence: [ScanIncompleteEvidence], truncated: Bool, root: URL, device: UInt64 = 0, inode: UInt64 = 0) {
        self.skipped = skipped
        self.evidenceRootPath = root.standardizedFileURL.path
        self.device = device
        self.inode = inode
        self.evidence = evidence.sorted { ($0.path, $0.reason) < ($1.path, $1.reason) }
        self.details = self.evidence.map { evidence in
            let path = URL(fileURLWithPath: evidence.path).standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            let relative = path == rootPath ? "." : path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            return relative.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥") + ": " + evidence.reason
        }
        self.canAcknowledge = !truncated && skipped > 0 && evidence.count == skipped && evidence.allSatisfy { Self.isAcknowledgeable(reason: $0.reason) }
    }

    private static func isAcknowledgeable(reason: String) -> Bool {
        reason == "excluded by sensitive path policy" || reason == "unreadable directory"
    }
}
public struct ScanLiveLocation: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let allocatedBytes: Int64
}
public struct ScanProgress: Sendable {
    public let entries: Int
    public let path: String
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let files: Int
    public let skipped: Int
    public let elapsed: Double
    /// Bytes macOS charged to this process since this scan began, if available.
    public let processDiskReadBytes: UInt64?
    public let locations: [ScanLiveLocation]
    public init(entries: Int, path: String, allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0, files: Int = 0, skipped: Int = 0, elapsed: Double = 0, processDiskReadBytes: UInt64? = nil, locations: [ScanLiveLocation] = []) {
        self.entries = entries; self.path = path; self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes; self.files = files; self.skipped = skipped
        self.elapsed = elapsed; self.processDiskReadBytes = processDiskReadBytes; self.locations = locations
    }
}
public enum ScanBackend: String, Sendable { case bulk, foundation, parallel }
public enum DiskFormat {
    public static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
