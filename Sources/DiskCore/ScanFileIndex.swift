import Darwin
import Foundation

public struct ScanFileEntry: Codable, Sendable, Equatable {
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modified: Date
    public let isSymlink: Bool
}

public struct ScanFileChange: Identifiable, Sendable {
    public enum Kind: String, Sendable { case added, removed, modified }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let before: ScanFileEntry?
    public let after: ScanFileEntry?
    public var logicalDelta: Int64 { (after?.logicalBytes ?? 0) - (before?.logicalBytes ?? 0) }
    public var allocatedDelta: Int64 { (after?.allocatedBytes ?? 0) - (before?.allocatedBytes ?? 0) }
}

public struct ScanFileDiff: Sendable {
    public let changes: [ScanFileChange]
    public let changeCount: Int
    public let truncated: Bool
    public let partialCoverage: Bool
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
}

/// Streaming, metadata-only sidecar. Each record is bounded independently;
/// history listings never load the full file index into memory.
public enum ScanFileIndex {
    private static let maxBytes: Int64 = 512 * 1024 * 1024
    private static let maxEntries = 2_000_000
    private struct Header: Codable {
        let version: Int
        let root: String
        let started: Date
        let partial: Bool
        let entryCount: Int
    }

    public static func url(id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(".\(id.uuidString).index")
    }

    public static func write(scan: ScanResult, id: UUID, directory: URL, byteBudget: Int64 = 512 * 1024 * 1024) throws {
        let destination = url(id: id, directory: directory)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).index-tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("Could not create the per-file index.") }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        var written: Int64 = 0
        func append<T: Encodable>(_ value: T) throws {
            var data = try encoder.encode(value); data.append(10)
            written += Int64(data.count)
            guard written <= min(maxBytes, byteBudget), data.count <= 1_048_576 else { throw failure("Per-file index exceeds its storage limit. Manage older records in History before saving more.") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure("Could not finish the per-file index.") }
                    offset += count
                }
            }
        }
        try append(Header(version: 1, root: scan.rootPath, started: scan.started,
                          partial: scan.skipped > 0 || !scan.errors.isEmpty || scan.nodes.first?.isScanIncomplete == true,
                          entryCount: scan.nodes.filter { !$0.isDirectory || $0.isSymlink }.count))
        guard scan.nodes.count <= maxEntries else { throw failure("Per-file index exceeds its entry limit.") }
        if let root = scan.nodes.first, !root.isDirectory || root.isSymlink {
            try append(ScanFileEntry(path: root.name, logicalBytes: root.logicalBytes, allocatedBytes: root.allocatedBytes, modified: root.modified, isSymlink: root.isSymlink))
        }
        var directories: [Int: String] = [0: ""]
        for node in scan.nodes.dropFirst() {
            if node.id & 255 == 0 { try Task.checkCancellation() }
            guard let parent = node.parent, let prefix = directories[parent] else { throw failure("Invalid scan hierarchy.") }
            let path = prefix.isEmpty ? node.name : prefix + "/" + node.name
            if node.isDirectory && !node.isSymlink { directories[node.id] = path }
            else {
                try append(ScanFileEntry(path: path, logicalBytes: node.logicalBytes, allocatedBytes: node.allocatedBytes,
                                         modified: node.modified, isSymlink: node.isSymlink))
            }
        }
        guard fsync(descriptor) == 0, link(temporary.path, destination.path) == 0 else { throw failure("Could not publish the per-file index.") }
    }

    public static func compare(before: SavedScanSnapshot, after: SavedScanSnapshot, directory: URL,
                               search: String = "", limit: Int = 100_000) throws -> ScanFileDiff {
        guard before.scan.rootPath == after.scan.rootPath else { throw failure("Choose two scans of the same folder.") }
        var old: [String: ScanFileEntry] = [:]
        let oldHeader = try read(id: before.id, directory: directory) { entry in
            guard old.updateValue(entry, forKey: entry.path) == nil else { throw failure("Duplicate path in the per-file index.") }
        }
        var changes: [ScanFileChange] = [], changeCount = 0
        var logical: Int64 = 0, allocated: Int64 = 0
        func record(_ change: ScanFileChange) {
            logical = adding(logical, change.logicalDelta)
            allocated = adding(allocated, change.allocatedDelta)
            if search.isEmpty || change.path.localizedCaseInsensitiveContains(search) {
                changeCount += 1
                if changes.count < max(0, limit) { changes.append(change) }
            }
        }
        var seen = Set<String>()
        let newHeader = try read(id: after.id, directory: directory) { entry in
            guard seen.insert(entry.path).inserted else { throw failure("Duplicate path in the per-file index.") }
            let previous = old.removeValue(forKey: entry.path)
            if let previous {
                if previous != entry { record(ScanFileChange(path: entry.path, kind: .modified, before: previous, after: entry)) }
            } else { record(ScanFileChange(path: entry.path, kind: .added, before: nil, after: entry)) }
        }
        guard oldHeader.root == before.scan.rootPath, newHeader.root == after.scan.rootPath,
              oldHeader.started == before.scan.started, newHeader.started == after.scan.started else {
            throw failure("The per-file index does not match its snapshot.")
        }
        for entry in old.values { record(ScanFileChange(path: entry.path, kind: .removed, before: entry, after: nil)) }
        changes.sort {
            let lhs = $0.logicalDelta.magnitude, rhs = $1.logicalDelta.magnitude
            return lhs == rhs ? $0.path < $1.path : lhs > rhs
        }
        return ScanFileDiff(changes: changes, changeCount: changeCount, truncated: changeCount > changes.count,
                            partialCoverage: oldHeader.partial || newHeader.partial, logicalDelta: logical, allocatedDelta: allocated)
    }

    private static func read(id: UUID, directory: URL, entry: (ScanFileEntry) throws -> Void) throws -> Header {
        let path = url(id: id, directory: directory)
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("This snapshot has no readable per-file index. Older snapshots contain top-level totals only.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxBytes else { throw failure("Invalid per-file index.") }
        let decoder = JSONDecoder()
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var header: Header?, count = 0, total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw failure("Could not read the per-file index.") }
            if size == 0 { break }
            total += Int64(size)
            guard total <= maxBytes else { throw failure("Index grew beyond its read limit.") }
            pending.append(contentsOf: buffer.prefix(size))
            while let end = pending.firstIndex(of: 10) {
                let line = pending[..<end]
                guard line.count <= 1_048_576 else { throw failure("Index record is too large.") }
                if header == nil {
                    header = try decoder.decode(Header.self, from: line)
                    guard header?.version == 1, let expected = header?.entryCount, (0...maxEntries).contains(expected) else { throw failure("Unsupported per-file index version.") }
                } else {
                    count += 1
                    guard count <= maxEntries else { throw failure("Index contains too many records.") }
                    let value = try decoder.decode(ScanFileEntry.self, from: line)
                    guard !value.path.isEmpty, !value.path.hasPrefix("/"), !value.path.contains("\0"),
                          value.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
                          value.logicalBytes >= 0, value.allocatedBytes >= 0 else { throw failure("Invalid index record.") }
                    try entry(value)
                }
                pending.removeSubrange(...end)
            }
            guard pending.count <= 1_048_576 else { throw failure("Index record is too large.") }
        }
        guard pending.isEmpty, let header, count == header.entryCount else { throw failure("Incomplete per-file index.") }
        return header
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? (rhs < 0 ? .min : .max) : sum.partialValue
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScanFileIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
