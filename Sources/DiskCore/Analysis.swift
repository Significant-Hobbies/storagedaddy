import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let nodeIDs: [Int]
    public let wastedBytes: Int64

    public init(id: String, nodeIDs: [Int], wastedBytes: Int64) {
        self.id = id
        self.nodeIDs = nodeIDs
        self.wastedBytes = wastedBytes
    }
}

public enum DiskAnalysisError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case metadataFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case fileMutated(path: String)
    case unsafePath(path: String, reason: String)
    case invalidExpectedMetadata(path: String)

    public var errorDescription: String? {
        switch self {
        case let .metadataFailed(path, reason):
            return "Could not inspect \(path): \(reason)"
        case let .readFailed(path, reason):
            return "Could not read \(path): \(reason)"
        case let .fileMutated(path):
            return "File changed while it was being inspected: \(path)"
        case let .unsafePath(path, reason):
            return "Refusing unsafe path \(path): \(reason)"
        case let .invalidExpectedMetadata(path):
            return "The expected metadata for \(path) is incomplete"
        }
    }

    public var description: String { errorDescription ?? "Disk analysis failed" }
}

public struct DuplicateSearchOptions: Sendable {
    public var coveragePercent: Int
    public var hashConcurrency: Int
    public var useHashCache: Bool
    public init(coveragePercent: Int = 100, hashConcurrency: Int = 4, useHashCache: Bool = true) {
        self.coveragePercent = min(100, max(1, coveragePercent))
        self.hashConcurrency = min(8, max(1, hashConcurrency))
        self.useHashCache = useHashCache
    }
}

public enum DuplicateFinder {
    private static let chunkSize = 1024 * 1024

    public static func find(in scan: ScanResult, options: DuplicateSearchOptions = .init(), log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [DuplicateGroup] {
        try Task.checkCancellation()

        // The scan already records logical size. Avoid even lstat/resource-value work
        // for sizes that cannot have a duplicate; this matters for large scans.
        var nodesBySize: [Int64: [Int]] = [:]
        for node in scan.nodes where !node.isDirectory {
            try Task.checkCancellation()
            nodesBySize[node.logicalBytes, default: []].append(node.id)
        }

        var results: [DuplicateGroup] = []
        // Keep node IDs for the disk, and materialize paths/candidates for one
        // matching-size group at a time instead of retaining every candidate.
        let rankedSizes = nodesBySize.keys.filter { (nodesBySize[$0]?.count ?? 0) > 1 }.sorted {
            let left = Double($0) * Double((nodesBySize[$0]?.count ?? 1) - 1)
            let right = Double($1) * Double((nodesBySize[$1]?.count ?? 1) - 1)
            return left == right ? $0 > $1 : left > right
        }
        let bucketCount = Int(ceil(Double(rankedSizes.count) * Double(options.coveragePercent) / 100))
        log("Checking \(bucketCount) of \(rankedSizes.count) eligible size groups (\(options.coveragePercent)% coverage)")
        for size in rankedSizes.prefix(bucketCount) {
            try Task.checkCancellation()
            var sameSize: [Candidate] = []
            var seenIdentities = Set<FileIdentity>()
            for id in nodesBySize[size] ?? [] {
                try Task.checkCancellation()
                let node = scan.nodes[id]
                let url = scan.url(for: id)
                guard !isSensitive(url) else { continue }
                let state = try fileState(at: url)

                // Symlinks and sensitive/offline files are deliberately excluded from analysis.
                guard !state.isSymlink,
                      state.isRegular,
                      !(try isCloudFileUnavailable(at: url)) else { continue }

                guard matchesScan(node, state: state) else {
                    throw DiskAnalysisError.fileMutated(path: url.path)
                }
                let identity = FileIdentity(device: state.device, inode: state.inode)
                // A hard link is one file with multiple names. Count its contents once.
                guard seenIdentities.insert(identity).inserted else { continue }
                sameSize.append(Candidate(node: node, url: url, state: state))
            }
            guard sameSize.count > 1 else { continue }

            log("Checking \(sameSize.count) candidates of \(size) bytes")
            // Prefix depth only filters candidates; all matches still receive full verification.
            var byPrefix: [Data: [Candidate]] = [:]
            for candidate in sameSize {
                try Task.checkCancellation()
                let prefix = try hash(candidate, limit: 4096)
                byPrefix[prefix, default: []].append(candidate)
            }
            var byDigest: [Data: [Candidate]] = [:]
            for candidates in byPrefix.values where candidates.count > 1 {
                // Bound simultaneous I/O and task count, including on huge groups.
                for offset in stride(from: 0, to: candidates.count, by: options.hashConcurrency) {
                    let batch = Array(candidates.dropFirst(offset).prefix(options.hashConcurrency))
                    let hashed = try await withThrowingTaskGroup(of: (Candidate, Data).self) { group in
                        for candidate in batch { group.addTask { (candidate, try await fullHash(candidate, useCache: options.useHashCache)) } }
                        var values: [(Candidate, Data)] = []
                        for try await value in group { values.append(value) }
                        return values
                    }
                    for (candidate, digest) in hashed { byDigest[digest, default: []].append(candidate) }
                }
            }

            for digest in byDigest.keys.sorted(by: { $0.base64EncodedString() < $1.base64EncodedString() }) {
                try Task.checkCancellation()
                guard let matches = byDigest[digest], matches.count > 1 else { continue }
                let hashed = matches.sorted { $0.node.id < $1.node.id }

                // SHA-256 is a prefilter. Establish equality by comparing bytes as well.
                var exactGroups: [[Candidate]] = []
                for candidate in hashed {
                    try Task.checkCancellation()
                    var matchingIndex: Int?
                    for index in exactGroups.indices {
                        if try equalBytes(candidate, exactGroups[index][0]) {
                            matchingIndex = index
                            break
                        }
                    }
                    if let matchingIndex {
                        exactGroups[matchingIndex].append(candidate)
                    } else {
                        exactGroups.append([candidate])
                    }
                }

                for exactGroup in exactGroups where exactGroup.count > 1 {
                    let nodeIDs = exactGroup.map { $0.node.id }.sorted()
                    // APFS can report sparse/compressed allocation smaller than logical
                    // size, so wasted space is the physical allocation of copies.
                    let wasted = try wastedAllocation(for: exactGroup)
                    let id = "\(size):\(nodeIDs.map(String.init).joined(separator: ","))"
                    results.append(DuplicateGroup(id: id, nodeIDs: nodeIDs, wastedBytes: wasted))
                }
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.wastedBytes != rhs.wastedBytes { return lhs.wastedBytes > rhs.wastedBytes }
            return lhs.id < rhs.id
        }
    }

    private struct Candidate: Sendable {
        let node: DiskNode
        let url: URL
        let state: FileState
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileState: Hashable, Sendable {
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let size: Int64
        let modified: Date
        let device: UInt64
        let inode: UInt64
        let isDirectory: Bool
        let isSymlink: Bool
        let isRegular: Bool
    }

    private static func wastedAllocation(for group: [Candidate]) throws -> Int64 {
        var total: Int64 = 0
        for candidate in group.dropFirst() {
            let allocation = candidate.node.allocatedBytes
            guard allocation >= 0 else {
                throw DiskAnalysisError.readFailed(path: candidate.url.path, reason: "negative allocation")
            }
            let result = total.addingReportingOverflow(allocation)
            guard !result.overflow else {
                throw DiskAnalysisError.readFailed(path: "<duplicate group>", reason: "allocation overflow")
            }
            total = result.partialValue
        }
        return total
    }

    private static func matchesScan(_ node: DiskNode, state: FileState) -> Bool {
        guard state.size == node.logicalBytes,
              state.isDirectory == node.isDirectory,
              state.isSymlink == node.isSymlink else { return false }
        if node.device != 0, node.device != state.device { return false }
        if node.inode != 0, node.inode != state.inode { return false }
        if node.modified != .distantPast, node.modified != state.modified { return false }
        return true
    }

    private struct CacheKey: Hashable, Sendable { let path: String; let state: FileState }
    private actor DigestCache {
        var values: [CacheKey: Data] = [:]
        func get(_ key: CacheKey) -> Data? { values[key] }
        func put(_ key: CacheKey, _ digest: Data) {
            if values.count >= 8192 { values.removeAll(keepingCapacity: true) }
            values[key] = digest
        }
    }
    private static let digestCache = DigestCache()
    private static func fullHash(_ candidate: Candidate, useCache: Bool) async throws -> Data {
        let key = CacheKey(path: candidate.url.path, state: candidate.state)
        if useCache, let digest = await digestCache.get(key) {
            let handle = try open(candidate); defer { try? handle.close() }
            try verifyUnchanged(candidate, descriptor: handle.fileDescriptor)
            return digest
        }
        let digest = try hash(candidate)
        if useCache { await digestCache.put(key, digest) }
        return digest
    }

    private static func hash(_ candidate: Candidate, limit: Int? = nil) throws -> Data {
        let handle = try open(candidate)
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while true {
            if remaining == 0 { break }
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
            } catch {
                throw DiskAnalysisError.readFailed(path: candidate.url.path, reason: error.localizedDescription)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        try verifyUnchanged(candidate, descriptor: handle.fileDescriptor)
        return Data(hasher.finalize())
    }

    private static func equalBytes(_ lhs: Candidate, _ rhs: Candidate) throws -> Bool {
        guard lhs.state.size == rhs.state.size else { return false }
        let leftHandle = try open(lhs)
        defer { try? leftHandle.close() }
        let rightHandle = try open(rhs)
        defer { try? rightHandle.close() }

        var equal = true
        while true {
            try Task.checkCancellation()
            let left: Data
            let right: Data
            do {
                left = try leftHandle.read(upToCount: chunkSize) ?? Data()
                right = try rightHandle.read(upToCount: chunkSize) ?? Data()
            } catch {
                let path = leftHandle.fileDescriptor >= 0 ? lhs.url.path : rhs.url.path
                throw DiskAnalysisError.readFailed(path: path, reason: error.localizedDescription)
            }
            if left != right { equal = false }
            if left.isEmpty || right.isEmpty { break }
        }
        try verifyUnchanged(lhs, descriptor: leftHandle.fileDescriptor)
        try verifyUnchanged(rhs, descriptor: rightHandle.fileDescriptor)
        return equal
    }

    private static func open(_ candidate: Candidate) throws -> FileHandle {
        guard !candidate.state.isSymlink, candidate.state.isRegular else {
            throw DiskAnalysisError.readFailed(path: candidate.url.path, reason: "not a regular file")
        }
        if isSensitive(candidate.url) {
            throw DiskAnalysisError.readFailed(path: candidate.url.path, reason: "sensitive path")
        }
        if try isCloudFileUnavailable(at: candidate.url) {
            throw DiskAnalysisError.readFailed(path: candidate.url.path, reason: "cloud-only file is unavailable")
        }

        let before = try fileState(at: candidate.url)
        guard before == candidate.state else {
            throw DiskAnalysisError.fileMutated(path: candidate.url.path)
        }
        let descriptor = posixOpen(candidate.url.path)
        guard descriptor >= 0 else {
            throw DiskAnalysisError.readFailed(path: candidate.url.path, reason: posixError())
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let descriptorState = try fileState(for: handle.fileDescriptor, path: candidate.url.path)
            guard descriptorState == before else {
                try? handle.close()
                throw DiskAnalysisError.fileMutated(path: candidate.url.path)
            }
        } catch {
            try? handle.close()
            throw error
        }
        return handle
    }

    private static func posixOpen(_ path: String) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        #else
        return Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        #endif
    }

    private static func verifyUnchanged(_ candidate: Candidate, descriptor: Int32) throws {
        let descriptorState = try fileState(for: descriptor, path: candidate.url.path)
        let pathState = try fileState(at: candidate.url)
        guard descriptorState == candidate.state, pathState == candidate.state else {
            throw DiskAnalysisError.fileMutated(path: candidate.url.path)
        }
    }

    private static func fileState(at url: URL) throws -> FileState {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw DiskAnalysisError.metadataFailed(path: url.path, reason: posixError())
        }
        return state(from: info)
    }

    private static func fileState(for descriptor: Int32, path: String) throws -> FileState {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw DiskAnalysisError.metadataFailed(path: path, reason: posixError())
        }
        return state(from: info)
    }

    private static func state(from info: stat) -> FileState {
        let mode = info.st_mode
        let kind = mode & S_IFMT
        #if canImport(Darwin)
        let seconds = TimeInterval(info.st_mtimespec.tv_sec)
        let nanos = TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        #else
        let seconds = TimeInterval(info.st_mtim.tv_sec)
        let nanos = TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000
        #endif
        #if canImport(Darwin)
        let changedSeconds = Int64(info.st_ctimespec.tv_sec), changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        #else
        let changedSeconds = Int64(info.st_ctim.tv_sec), changedNanoseconds = Int64(info.st_ctim.tv_nsec)
        #endif
        return FileState(
            changedSeconds: changedSeconds, changedNanoseconds: changedNanoseconds,
            size: Int64(info.st_size),
            modified: Date(timeIntervalSince1970: seconds + nanos),
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            isDirectory: kind == S_IFDIR,
            isSymlink: kind == S_IFLNK,
            isRegular: kind == S_IFREG
        )
    }

    private static func posixError() -> String {
        String(cString: strerror(errno))
    }

    private static func isCloudFileUnavailable(at url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])
            return values.isUbiquitousItem == true &&
                values.ubiquitousItemDownloadingStatus == .notDownloaded
        } catch {
            throw DiskAnalysisError.metadataFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    fileprivate static func isSensitive(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let lowerPath = path.lowercased()
        if path == "/" || path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return true
        }
        let protectedPrefixes = [
            "/system/",
            "/library/",
            "/private/etc/",
            "/private/var/db/",
            "/var/db/"
        ]
        if protectedPrefixes.contains(where: { lowerPath.hasPrefix($0) }) { return true }

        let components = path.split(separator: "/").map(String.init)
        let sensitiveComponents = Set([
            ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc",
            "keychains", "containers", "group containers"
        ])
        if components.contains(where: { sensitiveComponents.contains($0.lowercased()) }) { return true }
        if components.contains("Library"),
           components.contains(where: { ["Containers", "Group Containers", "Keychains"].contains($0) }) {
            return true
        }
        let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if filename.hasPrefix(".env") || filename == ".npmrc" ||
            filename == ".pypirc" || filename == "credentials" || filename == "secrets" ||
            filename.hasPrefix("credential.") || filename.hasPrefix("secret.") ||
            filename.hasPrefix("id_rsa") || filename.hasPrefix("id_ed25519") ||
            filename.hasSuffix(".pem") || filename.hasSuffix(".key") {
            return true
        }
        return false
    }
}

public enum CleanupSafety {
    public static func validate(url: URL, expected: DiskNode, root: URL) throws {
        try validate(url: url, expected: expected, root: root, allowingRegenerableChanges: false)
    }

    public static func validate(url: URL, expected: DiskNode, root: URL, allowingRegenerableChanges: Bool,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        let candidate = url.standardizedFileURL
        let rootURL = root.standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let physicalCandidate = try physicalURL(candidate)
        let physicalRoot = try physicalURL(rootURL)

        // APFS firmlinks are not symlinks: Foundation can resolve a Data-volume
        // child to /Users while leaving its scan root at /System/Volumes/Data.
        // POSIX realpath resolves actual symlinks without translating firmlinks.
        // Use that namespace for containment; Foundation's user-facing spelling
        // remains useful for recognizing protected and sensitive locations.
        guard physicalCandidate.path != physicalRoot.path,
              isDescendant(physicalCandidate.path, of: physicalRoot.path) else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "outside the scan root or is the root")
        }
        guard candidate.path == physicalCandidate.path else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "path traverses a symlink")
        }
        guard !isProtectedRoot(resolvedCandidate) else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "protected system or container root")
        }
        guard !DuplicateFinder.isSensitive(resolvedCandidate) else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "sensitive path")
        }
        let ancestors = candidate.path.lowercased().split(separator: "/").dropLast()
        guard !ancestors.contains(where: { $0.hasSuffix(".app") || $0.hasSuffix(".framework") || $0.hasSuffix(".xpc") }) else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "an installed app component; remove the whole app through Applications instead")
        }

        let actual = try state(at: candidate)
        let regenerable = allowingRegenerableChanges && expected.isDirectory
            && CleanupGuidance.isRegenerableFolder(path: candidate.path, home: home)
        guard !allowingRegenerableChanges || regenerable else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "rebuild or download inputs changed; review this folder again")
        }
        guard !actual.isSymlink else {
            throw DiskAnalysisError.unsafePath(path: candidate.path, reason: "symlink")
        }
        guard expected.isSymlink == false,
              actual.isDirectory == expected.isDirectory,
              expected.device != 0,
              expected.inode != 0,
              actual.device == expected.device,
              actual.inode == expected.inode,
              expected.modified != .distantPast,
              regenerable || actual.modified == expected.modified else {
            throw DiskAnalysisError.fileMutated(path: candidate.path)
        }
        // Directory st_size describes the directory record, while DiskNode stores
        // the aggregate subtree size. Only files can safely compare logical bytes.
        if !actual.isDirectory, actual.size != expected.logicalBytes {
            throw DiskAnalysisError.fileMutated(path: candidate.path)
        }
        try ChromeSigningClones.validateForCleanup(at: candidate)
    }

    private struct State {
        let size: Int64
        let modified: Date
        let device: UInt64
        let inode: UInt64
        let isDirectory: Bool
        let isSymlink: Bool
    }

    private static func physicalURL(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else {
            throw DiskAnalysisError.metadataFailed(path: url.path, reason: String(cString: strerror(errno)))
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
    }

    private static func state(at url: URL) throws -> State {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw DiskAnalysisError.metadataFailed(path: url.path, reason: String(cString: strerror(errno)))
        }
        let mode = info.st_mode
        let kind = mode & S_IFMT
        #if canImport(Darwin)
        let seconds = TimeInterval(info.st_mtimespec.tv_sec)
        let nanos = TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        #else
        let seconds = TimeInterval(info.st_mtim.tv_sec)
        let nanos = TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000
        #endif
        return State(
            size: Int64(info.st_size),
            modified: Date(timeIntervalSince1970: seconds + nanos),
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            isDirectory: kind == S_IFDIR,
            isSymlink: kind == S_IFLNK
        )
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    private static func isProtectedRoot(_ url: URL) -> Bool {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == "/" || path == home { return true }
        if path == "/System" || path.hasPrefix("/System/") ||
            path == "/Library" || path.hasPrefix("/Library/") ||
            path == "/Applications" {
            return true
        }
        return false
    }
}

public struct SnapshotDelta: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let before: Int64
    public let after: Int64
    public var change: Int64 { after - before }

    public init(id: String, name: String, before: Int64, after: Int64) {
        self.id = id
        self.name = name
        self.before = before
        self.after = after
    }
}

public enum SnapshotComparison {
    public static func compare(_ old: ScanResult, _ new: ScanResult) -> [SnapshotDelta] {
        let oldValues = topLevelValues(in: old)
        let newValues = topLevelValues(in: new)
        let names = Set(oldValues.keys).union(newValues.keys).sorted()

        return names.compactMap { name in
            let before = oldValues[name] ?? 0
            let after = newValues[name] ?? 0
            guard before != after else { return nil }
            return SnapshotDelta(id: name, name: name, before: before, after: after)
        }
    }

    private static func topLevelValues(in scan: ScanResult) -> [String: Int64] {
        let rootID = scan.nodes.first(where: { $0.parent == nil })?.id ?? 0
        return Dictionary(uniqueKeysWithValues: scan.nodes
            .filter { $0.parent == rootID }
            .map { ($0.name, $0.allocatedBytes) })
    }
}
