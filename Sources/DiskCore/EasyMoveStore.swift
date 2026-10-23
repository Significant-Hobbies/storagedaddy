import Foundation
import CryptoKit
import Darwin

public enum EasyMoveError: Error, LocalizedError, Sendable {
    case unsafe(String), changed(String), occupied(String), failed(String)
    public var errorDescription: String? {
        switch self {
        case .unsafe(let why): "Cannot move this item: \(why)"
        case .changed(let path): "\(path) changed after review. Nothing will be overwritten; review it again."
        case .occupied(let path): "\(path) already exists. Choose another destination; Easy Move never overwrites an item."
        case .failed(let why): "Easy Move stopped: \(why). Open move history to recover or restore."
        }
    }
}

public struct EasyMoveIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ value: stat) {
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino); mode = value.st_mode
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    var directory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode && mode == other.mode }
}

public struct EasyMovePlan: Codable, Sendable, Identifiable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let bytes: Int64
    public var sameVolume: Bool { !copyRequired }
    public var leavesSourceLink: Bool? = nil
    let copyRequired: Bool
    let sourceParent: EasyMoveIdentity
    let destinationParent: EasyMoveIdentity
    let manifest: [String: EasyMoveEntry]
    let exclusions: [String]
}

struct EasyMoveEntry: Codable, Equatable, Sendable {
    let identity: EasyMoveIdentity
    let digest: Data?
}

public struct EasyMoveRecord: Codable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case prepared, copying, destinationReady, sourceStaged, linked, completed, restoring, restored
    }
    public let plan: EasyMovePlan
    public var id: UUID { plan.id }
    public let created: Date
    public var phase: Phase
    public var message: String?
    var destinationIdentity: EasyMoveIdentity?
    var linkIdentity: EasyMoveIdentity?
    var restoreIdentity: EasyMoveIdentity?
    public var recoveryPaths: [URL] { [sourceBackup, destinationStage, restoreStage] }
    var sourceBackup: URL { plan.source.deletingLastPathComponent().appendingPathComponent(".StorageDaddy-move-\(id.uuidString)") }
    var destinationStage: URL { plan.destination.deletingLastPathComponent().appendingPathComponent(".StorageDaddy-move-\(id.uuidString)") }
    var restoreStage: URL { plan.source.deletingLastPathComponent().appendingPathComponent(".StorageDaddy-restore-\(id.uuidString)") }
}

/// Filesystem operations are serialized, local, and descriptor anchored. This is
/// a recovery journal, not a filesystem-wide transaction: quit applications that
/// might write these files, and keep the destination attached until restored.
public actor EasyMoveStore {
    private let journalDirectory: URL
    private let activeUse: @Sendable ([URL]) throws -> Void
    public init(journalDirectory: URL, activeUse: (@Sendable ([URL]) throws -> Void)? = nil) throws {
        self.journalDirectory = journalDirectory
        self.activeUse = activeUse ?? { try CleanupActiveUse.validate(urls: $0) }
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = try Self.openDirectory(journalDirectory); close(fd)
    }

    public static var defaultJournalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorageDaddy/EasyMoves", isDirectory: true)
    }

    public func history() throws -> [EasyMoveRecord] {
        let folder = try Self.openDirectory(journalDirectory); defer { close(folder) }
        return try Self.names(folder).filter { $0.hasSuffix(".json") }.map { name in
            let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.posix("read move journal") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            return try JSONDecoder().decode(EasyMoveRecord.self, from: handle.readToEnd() ?? Data())
        }.sorted { $0.created > $1.created }
    }

    public func prepare(source: URL, destinationFolder: URL, excludedFolders: [String] = [],
                        expected: DiskNode? = nil, scanRoot: URL? = nil, leaveSourceLink: Bool = true, destinationName: String? = nil) throws -> EasyMovePlan {
        try Task.checkCancellation()
        let source = source
        let name = destinationName ?? source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw EasyMoveError.unsafe("invalid destination name") }
        let destination = destinationFolder.appendingPathComponent(name)
        try Self.validatePolicy(source, exclusions: excludedFolders)
        if (try? source.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true { throw EasyMoveError.unsafe("a mounted volume root cannot be moved") }
        try Self.validatePolicy(destination, exclusions: excludedFolders)
        if let expected, let scanRoot { try CleanupSafety.validate(url: source, expected: expected, root: scanRoot) }
        guard !Self.contains(source.path, destination.path), !Self.contains(destination.path, source.path) else {
            throw EasyMoveError.unsafe("source and destination overlap")
        }
        let sourceParent = try Self.openDirectory(source.deletingLastPathComponent()); defer { close(sourceParent) }
        let targetParent = try Self.openDirectory(destinationFolder); defer { close(targetParent) }
        try Self.requireAbsent(targetParent, destination.lastPathComponent)
        try activeUse([source])
        let manifest = try Self.manifest(parent: sourceParent, name: source.lastPathComponent, path: source.path, exclusions: excludedFolders)
        let sourceIdentity = try Self.identity(sourceParent), destinationIdentity = try Self.identity(targetParent)
        var plan = EasyMovePlan(id: UUID(), source: source, destination: destination,
            bytes: manifest.values.filter { !$0.identity.directory }.reduce(0) { $0 + $1.identity.size },
            copyRequired: sourceIdentity.device != destinationIdentity.device,
            sourceParent: sourceIdentity, destinationParent: destinationIdentity,
            manifest: manifest, exclusions: excludedFolders)
        plan.leavesSourceLink = leaveSourceLink
        return plan
    }

    public func execute(reviewedPlan plan: EasyMovePlan) throws -> EasyMoveRecord {
        var record = EasyMoveRecord(plan: plan, created: Date(), phase: .prepared)
        try save(record) // Recovery data exists before the first mutation.
        do {
            let sourceParent = try Self.checkedParent(plan.source, expected: plan.sourceParent); defer { close(sourceParent) }
            let targetParent = try Self.checkedParent(plan.destination, expected: plan.destinationParent); defer { close(targetParent) }
            try Self.requireAbsent(targetParent, plan.destination.lastPathComponent)
            try Self.requireAbsent(sourceParent, record.sourceBackup.lastPathComponent)
            try activeUse([plan.source])
            guard try Self.manifest(parent: sourceParent, name: plan.source.lastPathComponent, path: plan.source.path, exclusions: plan.exclusions) == plan.manifest else { throw EasyMoveError.changed(plan.source.path) }
            try Task.checkCancellation()
            if plan.sameVolume {
                // Exclusive rename is atomic on one filesystem.
                try Self.rename(sourceParent, plan.source.lastPathComponent, targetParent, plan.destination.lastPathComponent)
            } else {
                record.phase = .copying; try save(record)
                try Self.copyTree(sourceParent, plan.source.lastPathComponent, targetParent, record.destinationStage.lastPathComponent)
                let copied = try Self.manifest(parent: targetParent, name: record.destinationStage.lastPathComponent, path: record.destinationStage.path, exclusions: [])
                guard Self.sameContents(plan.manifest, copied),
                      try Self.manifest(parent: sourceParent, name: plan.source.lastPathComponent, path: plan.source.path, exclusions: plan.exclusions) == plan.manifest else { throw EasyMoveError.changed(plan.source.path) }
                try Task.checkCancellation()
                try Self.rename(targetParent, record.destinationStage.lastPathComponent, targetParent, plan.destination.lastPathComponent)
            }
            record.destinationIdentity = try Self.identity(targetParent, plan.destination.lastPathComponent)
            if plan.sameVolume, let original = plan.manifest[""]?.identity,
               !original.sameObject(record.destinationIdentity!) { throw EasyMoveError.changed(plan.source.path) }
            record.phase = .destinationReady; try save(record)
            // Cancellation after the first rename is recovered through the same journal.
            try Task.checkCancellation()
            if !plan.sameVolume {
                try activeUse([plan.source])
                guard try Self.manifest(parent: sourceParent, name: plan.source.lastPathComponent, path: plan.source.path, exclusions: plan.exclusions) == plan.manifest else { throw EasyMoveError.changed(plan.source.path) }
                try Self.rename(sourceParent, plan.source.lastPathComponent, sourceParent, record.sourceBackup.lastPathComponent)
            }
            record.phase = .sourceStaged; try save(record)
            if plan.leavesSourceLink != false {
                guard symlinkat(plan.destination.path, sourceParent, plan.source.lastPathComponent) == 0 else { throw Self.posix("create source link") }
                record.linkIdentity = try Self.identity(sourceParent, plan.source.lastPathComponent)
            }
            guard fsync(sourceParent) == 0 else { throw Self.posix("sync source link") }
            record.phase = .linked; try save(record)
            if !plan.sameVolume {
                // No cancellation while removing the verified obsolete source. The
                // durable destination already contains a checksum-verified copy.
                let backup = try Self.manifest(parent: sourceParent, name: record.sourceBackup.lastPathComponent, path: record.sourceBackup.path, exclusions: [])
                guard Self.sameContents(plan.manifest, backup) else { throw EasyMoveError.changed(record.sourceBackup.path) }
                try Self.removeTree(sourceParent, record.sourceBackup.lastPathComponent, manifest: backup)
            }
            record.phase = .completed; record.message = nil; try save(record)
            return record
        } catch {
            record.message = error.localizedDescription
            try? save(record)
            throw error
        }
    }

    /// Restores the destination's *current* contents, so edits made through the
    /// source link survive. It refuses a replaced source link or destination.
    public func rollback(recordID: UUID) throws -> EasyMoveRecord {
        guard var record = try history().first(where: { $0.id == recordID }) else { throw EasyMoveError.failed("move journal is missing") }
        let plan = record.plan
        try Self.validatePolicy(plan.source, exclusions: plan.exclusions)
        try Self.validatePolicy(plan.destination, exclusions: plan.exclusions)
        let sourceParent = try Self.checkedParent(plan.source, expected: plan.sourceParent); defer { close(sourceParent) }
        let targetParent = try Self.checkedParent(plan.destination, expected: plan.destinationParent); defer { close(targetParent) }
        try activeUse([plan.source, plan.destination])
        let sourceState = try Self.optionalIdentity(sourceParent, plan.source.lastPathComponent)
        let destinationState = try Self.optionalIdentity(targetParent, plan.destination.lastPathComponent)
        // A crash may occur between a mutation and its next journal update. Only
        // adopt an unrecorded destination if its complete reviewed manifest matches.
        if let destinationState {
            if let expected = record.destinationIdentity {
                guard expected.sameObject(destinationState) else { throw EasyMoveError.changed(plan.destination.path) }
            } else {
                let found = try Self.manifest(parent: targetParent, name: plan.destination.lastPathComponent, path: plan.destination.path, exclusions: [])
                guard Self.sameContents(plan.manifest, found) else { throw EasyMoveError.changed(plan.destination.path) }
                record.destinationIdentity = destinationState
            }
        }
        if let sourceState, sourceState.mode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
            // Link identity plus exact stored target; never remove another link.
            guard record.linkIdentity.map({ $0.sameObject(sourceState) }) ?? (record.phase == .sourceStaged),
                  try Self.linkTarget(sourceParent, plan.source.lastPathComponent) == plan.destination.path else { throw EasyMoveError.changed(plan.source.path) }
        } else if sourceState != nil {
            // A cross-volume interruption may leave the unchanged original and
            // verified destination. Stage that original before restoring edits.
            if destinationState != nil, !plan.sameVolume,
               try Self.manifest(parent: sourceParent, name: plan.source.lastPathComponent, path: plan.source.path, exclusions: plan.exclusions) == plan.manifest {
                try Self.rename(sourceParent, plan.source.lastPathComponent, sourceParent, record.sourceBackup.lastPathComponent)
            } else {
                if destinationState != nil, record.phase == .restoring,
                   let restored = record.restoreIdentity, restored.sameObject(sourceState!),
                   Self.sameContents(try Self.manifest(parent: sourceParent, name: plan.source.lastPathComponent, path: plan.source.path, exclusions: plan.exclusions),
                                     try Self.manifest(parent: targetParent, name: plan.destination.lastPathComponent, path: plan.destination.path, exclusions: plan.exclusions)) {
                    record.phase = .restored; record.message = "Restored after interruption. The destination copy is retained for review."; try save(record); return record
                }
                guard destinationState == nil else { throw EasyMoveError.failed("the original location is occupied; both copies were preserved") }
                record.phase = .restored; record.message = "Original retained. Review any unfinished staging copies in move history."; try save(record); return record
            }
        }
        guard let destinationState else {
            // Interrupted cross-volume copy leaves the original untouched.
            if sourceState == nil, let backup = try Self.optionalIdentity(sourceParent, record.sourceBackup.lastPathComponent) {
                guard backup.sameObject(plan.manifest[""]!.identity) else { throw EasyMoveError.changed(record.sourceBackup.path) }
                try Self.rename(sourceParent, record.sourceBackup.lastPathComponent, sourceParent, plan.source.lastPathComponent)
            }
            record.phase = .restored; record.message = "Original retained. Any unfinished destination staging copy is listed in this journal for review."
            try save(record); return record
        }
        record.phase = .restoring; try save(record)
        if plan.sameVolume {
            if (sourceState?.mode ?? 0) & UInt16(S_IFMT) == UInt16(S_IFLNK) { try Self.removeOwnedLink(sourceParent, plan.source.lastPathComponent, record: record) }
            try Self.rename(targetParent, plan.destination.lastPathComponent, sourceParent, plan.source.lastPathComponent)
        } else {
            let current = try Self.manifest(parent: targetParent, name: plan.destination.lastPathComponent, path: plan.destination.path, exclusions: plan.exclusions)
            if let existing = try Self.optionalIdentity(sourceParent, record.restoreStage.lastPathComponent) {
                guard let expected = record.restoreIdentity, existing.sameObject(expected) else { throw EasyMoveError.failed("an unverified restore staging copy exists at " + record.restoreStage.path) }
            } else {
                try Self.copyTree(targetParent, plan.destination.lastPathComponent, sourceParent, record.restoreStage.lastPathComponent)
            }
            let restored = try Self.manifest(parent: sourceParent, name: record.restoreStage.lastPathComponent, path: record.restoreStage.path, exclusions: [])
            guard Self.sameContents(current, restored),
                  try Self.manifest(parent: targetParent, name: plan.destination.lastPathComponent, path: plan.destination.path, exclusions: plan.exclusions) == current else { throw EasyMoveError.changed(plan.destination.path) }
            record.restoreIdentity = restored[""]!.identity; try save(record)
            try Task.checkCancellation()
            if (sourceState?.mode ?? 0) & UInt16(S_IFMT) == UInt16(S_IFLNK) { try Self.removeOwnedLink(sourceParent, plan.source.lastPathComponent, record: record) }
            try Self.rename(sourceParent, record.restoreStage.lastPathComponent, sourceParent, plan.source.lastPathComponent)
            // Both copies are retained until the restored source has been published.
            try Self.removeTree(targetParent, plan.destination.lastPathComponent, manifest: current)
            if let backup = try Self.optionalIdentity(sourceParent, record.sourceBackup.lastPathComponent) {
                let original = try Self.manifest(parent: sourceParent, name: record.sourceBackup.lastPathComponent, path: record.sourceBackup.path, exclusions: [])
                if Self.sameContents(plan.manifest, original), backup.sameObject(plan.manifest[""]!.identity) {
                    try Self.removeTree(sourceParent, record.sourceBackup.lastPathComponent, manifest: original)
                } else {
                    record.message = "Original restored. An incomplete source backup was retained for review: " + record.sourceBackup.path
                }
            }
        }
        record.phase = .restored; try save(record)
        return record
    }

    private func save(_ record: EasyMoveRecord) throws {
        let folder = try Self.openDirectory(journalDirectory); defer { close(folder) }
        let name = record.id.uuidString + ".json", temporary = "." + UUID().uuidString
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posix("create journal") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: JSONEncoder().encode(record)); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard renameat(folder, temporary, folder, name) == 0, fsync(folder) == 0 else { throw Self.posix("save journal") }
    }

    private static func validatePolicy(_ url: URL, exclusions: [String]) throws {
        let path = url.path, parts = path.lowercased().split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.contains("."), !parts.contains("..") else { throw EasyMoveError.unsafe("path must be absolute and contain no relative components") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/", home, "/Users", "/Volumes", "/Applications", "/Library", "/System", "/usr", "/bin", "/sbin", "/private", home + "/Library"]
        let forbidden = Set([".ssh", ".aws", ".kube", ".gnupg", ".docker", "keychains", "containers", "group containers"])
        let name = url.lastPathComponent.lowercased()
        let installedRuntimes = ["/opt/homebrew", "/usr/local", home + "/.nvm", home + "/.pyenv/versions", home + "/.rustup/toolchains", home + "/.volta/tools", home + "/.asdf/installs", home + "/.local/share/uv/python", home + "/.local/bin", home + "/.bun/bin"]
        guard !installedRuntimes.contains(where: { contains($0, path) }), !roots.contains(path), !["/System/", "/Library/", "/Applications/", "/usr/", "/bin/", "/sbin/", "/private/etc/", "/private/var/db/"].contains(where: path.hasPrefix),
              !parts.contains(where: { forbidden.contains($0) || $0.hasSuffix(".app") || $0.hasSuffix(".framework") || $0.hasSuffix(".xpc") }),
              !name.hasPrefix(".env"), ![".netrc", ".npmrc", ".pypirc", "credentials", "secrets"].contains(name),
              !name.hasPrefix("credential."), !name.hasPrefix("secret."), !name.hasPrefix("id_rsa"), !name.hasPrefix("id_ed25519"), !name.hasSuffix(".pem"), !name.hasSuffix(".key"),
              !FolderExclusions(paths: exclusions).blocksCleanup(url) else { throw EasyMoveError.unsafe("protected, excluded, sensitive or installed-app path: \(path)") }
    }
    private static func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    private static func posix(_ action: String) -> EasyMoveError { .failed(action + ": " + String(cString: strerror(errno))) }
    private static func identity(_ fd: Int32) throws -> EasyMoveIdentity { var value = stat(); guard fstat(fd, &value) == 0 else { throw posix("read identity") }; return EasyMoveIdentity(value) }
    private static func identity(_ parent: Int32, _ name: String) throws -> EasyMoveIdentity { guard let value = try optionalIdentity(parent, name) else { throw EasyMoveError.changed(name) }; return value }
    private static func optionalIdentity(_ parent: Int32, _ name: String) throws -> EasyMoveIdentity? {
        var value = stat(); if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return EasyMoveIdentity(value) }
        if errno == ENOENT { return nil }; throw posix("read \(name)")
    }
    private static func requireAbsent(_ parent: Int32, _ name: String) throws { if try optionalIdentity(parent, name) != nil { throw EasyMoveError.occupied(name) } }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix("open root") }
        for part in url.pathComponents.dropFirst() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd); guard next >= 0 else { throw EasyMoveError.unsafe("unreadable directory or symlink ancestor (\(part): \(String(cString: strerror(errno)))): \(url.path)") }; fd = next
        }
        return fd
    }
    private static func checkedParent(_ url: URL, expected: EasyMoveIdentity) throws -> Int32 {
        let fd = try openDirectory(url.deletingLastPathComponent())
        guard try expected.sameObject(identity(fd)) else { close(fd); throw EasyMoveError.changed(url.deletingLastPathComponent().path) }; return fd
    }
    private static func names(_ fd: Int32) throws -> [String] {
        let descriptor = dup(fd); guard descriptor >= 0 else { throw posix("duplicate directory") }
        guard let directory = fdopendir(descriptor) else { close(descriptor); throw posix("read directory") }
        defer { closedir(directory) }; rewinddir(directory)
        var result: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name) }
        }
        return result.sorted()
    }
    private static func manifest(parent: Int32, name: String, path: String, exclusions: [String]) throws -> [String: EasyMoveEntry] {
        var result: [String: EasyMoveEntry] = [:]
        func visit(_ parent: Int32, _ name: String, _ relative: String, _ path: String) throws {
            try Task.checkCancellation(); try validatePolicy(URL(fileURLWithPath: path), exclusions: exclusions)
            let before = try identity(parent, name)
            guard before.mode & UInt16(S_IFMT) == UInt16(S_IFREG) || before.directory else { throw EasyMoveError.unsafe("symbolic links and special files must be moved separately in Finder: \(path)") }
            guard result.count < 500_000 else { throw EasyMoveError.unsafe("more than 500,000 items; choose a smaller folder") }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (before.directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw posix("open \(path)") }; defer { close(fd) }
            guard try identity(fd) == before else { throw EasyMoveError.changed(path) }
            let digest: Data?
            if !before.directory {
                let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                guard values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus != .notDownloaded else {
                    throw EasyMoveError.unsafe("cloud-only files must be downloaded explicitly before review: " + path)
                }
            }
            if before.directory {
                digest = nil
                for child in try names(fd) { try visit(fd, child, relative.isEmpty ? child : relative + "/" + child, path + "/" + child) }
            } else { digest = try hash(fd) }
            guard try identity(fd) == before, try identity(parent, name) == before else { throw EasyMoveError.changed(path) }
            result[relative] = EasyMoveEntry(identity: before, digest: digest)
        }
        try visit(parent, name, "", path); return result
    }
    private static func hash(_ fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw posix("seek file") }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw posix("read file") }; if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return Data(hash.finalize())
    }
    private static func sameContents(_ lhs: [String: EasyMoveEntry], _ rhs: [String: EasyMoveEntry]) -> Bool {
        guard lhs.keys.sorted() == rhs.keys.sorted() else { return false }
        return lhs.allSatisfy { path, value in
            guard let other = rhs[path] else { return false }
            return value.identity.directory == other.identity.directory && value.digest == other.digest &&
                (value.identity.directory || value.identity.size == other.identity.size) && value.identity.mode == other.identity.mode
        }
    }
    private static func copyTree(_ sourceParent: Int32, _ sourceName: String, _ targetParent: Int32, _ targetName: String) throws {
        try Task.checkCancellation(); try requireAbsent(targetParent, targetName)
        let before = try identity(sourceParent, sourceName)
        let input = openat(sourceParent, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (before.directory ? O_DIRECTORY : 0))
        guard input >= 0 else { throw posix("open copy source") }; defer { close(input) }
        guard try identity(input) == before else { throw EasyMoveError.changed(sourceName) }
        if before.directory {
            guard mkdirat(targetParent, targetName, 0o700) == 0 else { throw posix("create destination folder") }
            let output = openat(targetParent, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw posix("open destination folder") }; defer { close(output) }
            for child in try names(input) { try copyTree(input, child, output, child) }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw posix("copy folder metadata") }
            guard fsync(output) == 0 else { throw posix("sync destination folder") }
        } else {
            guard before.mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { throw EasyMoveError.unsafe("copy source contains a symbolic link or special file") }
            let output = openat(targetParent, targetName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw posix("create destination file") }; defer { close(output) }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0, fsync(output) == 0 else { throw posix("copy destination file") }
        }
        guard try identity(input) == before, try identity(sourceParent, sourceName) == before else { throw EasyMoveError.changed(sourceName) }
    }
    private static func rename(_ a: Int32, _ name: String, _ b: Int32, _ destination: String) throws {
        guard renameatx_np(a, name, b, destination, UInt32(RENAME_EXCL)) == 0 else { if errno == EEXIST { throw EasyMoveError.occupied(destination) }; throw posix("move item") }
        guard fsync(a) == 0, fsync(b) == 0 else { throw posix("sync move") }
    }
    private static func linkTarget(_ parent: Int32, _ name: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(parent, name, &buffer, buffer.count - 1)
        guard count >= 0, count < buffer.count - 1 else { throw posix("read source link") }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private static func removeOwnedLink(_ parent: Int32, _ name: String, record: EasyMoveRecord) throws {
        let actual = try identity(parent, name)
        guard actual.mode & UInt16(S_IFMT) == UInt16(S_IFLNK), record.linkIdentity.map({ $0.sameObject(actual) }) ?? false,
              try linkTarget(parent, name) == record.plan.destination.path else { throw EasyMoveError.changed(record.plan.source.path) }
        guard unlinkat(parent, name, 0) == 0 else { throw posix("remove owned source link") }
    }
    private static func removeTree(_ parent: Int32, _ name: String, manifest: [String: EasyMoveEntry], relative: String = "") throws {
        guard let expected = manifest[relative]?.identity, try identity(parent, name) == expected else { throw EasyMoveError.changed(name) }
        if expected.directory {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posix("open verified obsolete copy") }; defer { close(fd) }
            guard try identity(fd) == expected else { throw EasyMoveError.changed(name) }
            let children = try names(fd)
            let prefix = relative.isEmpty ? "" : relative + "/"
            let expectedChildren = manifest.keys.filter { $0.hasPrefix(prefix) && $0 != relative && !$0.dropFirst(prefix.count).contains("/") }.map { String($0.dropFirst(prefix.count)) }.sorted()
            guard children == expectedChildren else { throw EasyMoveError.changed(name) }
            for child in children { try removeTree(fd, child, manifest: manifest, relative: prefix + child) }
            guard try identity(parent, name).sameObject(expected), unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posix("remove empty obsolete folder") }
        } else {
            guard expected.mode & UInt16(S_IFMT) == UInt16(S_IFREG), try identity(parent, name) == expected,
                  unlinkat(parent, name, 0) == 0 else { throw posix("remove verified obsolete file") }
        }
    }
}
