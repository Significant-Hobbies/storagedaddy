import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SavedScanSnapshot: Codable, Sendable, Identifiable {
    public let id: UUID
    public let savedAt: Date
    public let scan: ScanResult
    public var fileIndexVersion: Int? = nil
    public var fullTreeVersion: Int? = nil
    public var archivalWarning: String? = nil

    public init(id: UUID, savedAt: Date, scan: ScanResult) {
        self.id = id
        self.savedAt = savedAt
        self.scan = scan
    }
}

public struct SnapshotHistoryListing: Sendable {
    public let snapshots: [SavedScanSnapshot]
    public let unreadableCount: Int
    public let limitReached: Bool

    public init(snapshots: [SavedScanSnapshot], unreadableCount: Int, limitReached: Bool) {
        self.snapshots = snapshots
        self.unreadableCount = unreadableCount
        self.limitReached = limitReached
    }
}

public enum SnapshotHistoryStore {
    private static let maximumEntries = 512
    private static let maximumFileBytes: Int64 = 8 * 1024 * 1024

    public static func save(scan: ScanResult, directory: URL, savedAt: Date = Date(), includeFileIndex: Bool = false) throws -> SavedScanSnapshot {
        try prepare(directory: directory)
        var saved = SavedScanSnapshot(id: UUID(), savedAt: savedAt, scan: SnapshotArchive.compact(scan))
        try SnapshotArchive.validate(saved.scan)
        var data = try JSONEncoder().encode(saved)
        guard data.count <= maximumFileBytes else { throw error("Compact snapshot exceeds the history file limit.") }
        var snapshotPublished = false
        defer {
            if !snapshotPublished {
                try? FileManager.default.removeItem(at: ScanFileIndex.url(id: saved.id, directory: directory))
                try? FileManager.default.removeItem(at: ScanTreeArchive.url(id: saved.id, directory: directory))
            }
        }
        if includeFileIndex {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard entries.filter({ $0.pathExtension == "json" }).count < maximumEntries else {
                throw error("History reached its 512-scan limit. Move older records to Trash from History before saving more scans.")
            }
            var used: Int64 = 0
            for entry in entries where ["index", "tree", "json"].contains(entry.pathExtension) {
                var info = stat()
                if lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { used = min(2 * 1024 * 1024 * 1024, used + min(2 * 1024 * 1024 * 1024, max(0, Int64(info.st_size)))) }
            }
            let budget: Int64 = 2 * 1024 * 1024 * 1024 - used - Int64(data.count) - 4096
            guard budget > 0 else { throw error("History reached its 2 GB storage limit. Move older records to Trash from History before saving more scans.") }
            do {
                try Task.checkCancellation()
                try ScanFileIndex.write(scan: scan, id: saved.id, directory: directory, byteBudget: budget)
                saved.fileIndexVersion = 1
                let indexSize = try ScanFileIndex.url(id: saved.id, directory: directory).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try ScanTreeArchive.write(scan: scan, id: saved.id, directory: directory, byteBudget: budget - Int64(indexSize))
                saved.fullTreeVersion = 1
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let retained = saved.fileIndexVersion == 1 ? "Summary and file comparisons saved; reopening the full map is unavailable." : "Summary saved; file comparisons and reopening the full map are unavailable."
                saved.archivalWarning = retained + " " + String(error.localizedDescription.prefix(512))
            }
            data = try JSONEncoder().encode(saved)
            guard data.count <= maximumFileBytes else { throw error("Compact snapshot exceeds the history file limit.") }
        }
        try Task.checkCancellation()

        let timestamp = Int64(savedAt.timeIntervalSince1970 * 1_000_000)
        let filename = String(format: "%020lld-%@.json", timestamp, saved.id.uuidString)
        let temporary = directory.appendingPathComponent(".\(saved.id.uuidString).tmp")
        let destination = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeTemporary(data, to: temporary)
        guard link(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        snapshotPublished = true
        return saved
    }

    public static func load(directory: URL) throws -> SnapshotHistoryListing {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return SnapshotHistoryListing(snapshots: [], unreadableCount: 0, limitReached: false)
        }
        try validateDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted {
            let left = filenameIdentity($0)?.timestamp ?? Int64.min
            let right = filenameIdentity($1)?.timestamp ?? Int64.min
            return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
        }
        let limitReached = entries.count > maximumEntries
        var snapshots: [SavedScanSnapshot] = []
        var unreadable = 0

        for url in entries.prefix(maximumEntries) {
            do {
                guard let identity = filenameIdentity(url) else { throw error("Invalid history filename.") }
                let value = try JSONDecoder().decode(SavedScanSnapshot.self, from: readBounded(url))
                guard identity.id == value.id else {
                    throw error("Snapshot identity does not match its filename.")
                }
                try SnapshotArchive.validate(value.scan)
                var saved = SavedScanSnapshot(id: value.id, savedAt: value.savedAt, scan: SnapshotArchive.compact(value.scan))
                saved.fileIndexVersion = value.fileIndexVersion
                saved.fullTreeVersion = value.fullTreeVersion
                saved.archivalWarning = value.archivalWarning
                snapshots.append(saved)
            } catch {
                unreadable += 1
            }
        }
        snapshots.sort { $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt }
        return SnapshotHistoryListing(snapshots: snapshots, unreadableCount: unreadable, limitReached: limitReached)
    }

    /// Retention affects saved metadata only. The app obtains native consent
    /// before enabling this policy; every removal keeps the system Trash path.
    public static func excessSnapshots(_ snapshots: [SavedScanSnapshot], retainingPerRoot count: Int) -> [SavedScanSnapshot] {
        guard (7...30).contains(count) else { return [] }
        return Dictionary(grouping: snapshots, by: { $0.scan.rootPath }).values.flatMap { group in
            group.sorted { $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt }.dropFirst(count)
        }.sorted { $0.savedAt < $1.savedAt }
    }

    public static func trash(id: UUID, directory: URL, moveToTrash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) throws {
        try validateDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let record = entries.first(where: { filenameIdentity($0)?.id == id }) else { throw error("The saved record is unavailable.") }
        // Retain the listing on partial failure so its remaining sidecars can
        // still be retried from History.
        for sidecar in [ScanFileIndex.url(id: id, directory: directory), ScanTreeArchive.url(id: id, directory: directory)] {
            var info = stat()
            if lstat(sidecar.path, &info) == 0 { try moveToTrash(sidecar) }
        }
        try moveToTrash(record)
    }

    private static func prepare(directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateDirectory(directory)
    }

    private static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw error("Snapshot history location is not a regular directory.")
        }
    }

    private static func filenameIdentity(_ url: URL) -> (timestamp: Int64, id: UUID)? {
        guard url.pathExtension.lowercased() == "json" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 37 else { return nil }
        let idStart = name.index(name.endIndex, offsetBy: -36)
        guard name[name.index(before: idStart)] == "-",
              let id = UUID(uuidString: String(name[idStart...])),
              let timestamp = Int64(name[..<name.index(before: idStart)]) else { return nil }
        return (timestamp, id)
    }

    private static func writeTemporary(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(descriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              Int64(before.st_size) <= maximumFileBytes else { throw error("Invalid or oversized history entry.") }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = read(descriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw error("History entry changed while reading.") }
                offset += count
            }
        }
        var after = stat(), pathInfo = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &pathInfo) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              after.st_dev == pathInfo.st_dev, after.st_ino == pathInfo.st_ino, after.st_size == pathInfo.st_size,
              pathInfo.st_mode & S_IFMT == S_IFREG else { throw error("History entry changed while reading.") }
        return data
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SnapshotHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
