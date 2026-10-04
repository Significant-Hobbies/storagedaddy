import Darwin
import Dispatch
import Foundation

/// A metadata-only filesystem scanner. It never reads file contents.
public enum DiskScanner {
    public static func scan(
        root: URL,
        backend: ScanBackend = .parallel,
        parallelism: Int = 0,
        excludedFolders: [String] = [],
        promptAvoidanceFolders: [String] = [],
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        // Resolve ancestor aliases (for example /var -> /private/var), preserving
        // a symbolic-link leaf as a link rather than traversing its destination.
        let cancellation = ScanCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let canonical = root.path == "/" ? root : root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent)
            var scanner = Scanner(root: canonical, backend: backend, parallelism: parallelism,
                                  exclusions: FolderExclusions(paths: excludedFolders),
                                  promptAvoidance: FolderExclusions(paths: promptAvoidanceFolders, resolveAliases: false),
                                  cancellation: cancellation, progress: progress)
            return try scanner.run()
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }

    static func automaticParallelism(rootPath: String, rootDevice: UInt64, parentDevice: UInt64?, processorCount: Int) -> Int {
        // The disk picker uses this startup-data path. On some macOS layouts
        // it shares its parent's device number, so a device comparison alone
        // incorrectly selects the smaller folder pool for a whole-disk scan.
        let volumeRoot = rootPath == "/" || rootPath == "/System/Volumes/Data"
            || parentDevice.map { $0 != rootDevice } == true
        return min(max(1, processorCount), volumeRoot ? 16 : 4)
    }
}

private struct Scanner {
    private static let maximumErrors = 100
    private static let maximumIncompleteEvidence = 512
    private let root: URL
    private let rootPath: String
    private let backend: ScanBackend
    private let exclusions: FolderExclusions
    private let promptAvoidance: FolderExclusions
    private let parallelism: Int
    private let cancellation: ScanCancellation
    private var linkedAllocations: [(id: Int, bytes: Int64)] = []
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private var nodes: [DiskNode] = []
    private var errors: [String] = []
    private var skipped = 0
    private var incompleteEvidence: [ScanIncompleteEvidence] = []
    private var incompleteEvidenceTruncated = false
    private var allocatedInodes: Set<FileIdentity> = []
    private var rootDevice: UInt64 = 0
    private var backendCounters = DiskScannerBackendCounters()
    private var lastProgress: ContinuousClock.Instant?
    private let liveStart = ContinuousClock.now
    private let diskReadStart: UInt64?
    private var liveAllocated: Int64 = 0
    private var liveLogical: Int64 = 0
    private var liveFiles = 0
    private var liveRootBytes: [Int: Int64] = [:]
    private var liveLeaders: [Int] = []
    private var livePendingOwner: Int?
    private var livePendingBytes: Int64 = 0

    init(root: URL, backend: ScanBackend, parallelism: Int, exclusions: FolderExclusions,
         promptAvoidance: FolderExclusions, cancellation: ScanCancellation, progress: (@Sendable (ScanProgress) -> Void)?) {
        self.exclusions = exclusions
        self.promptAvoidance = promptAvoidance
        self.root = root
        self.rootPath = root.path
        self.backend = backend
        self.parallelism = max(0, min(64, parallelism))
        self.cancellation = cancellation
        self.progress = progress
        self.diskReadStart = ProcessMemory.diskReadBytes()
    }

    mutating func run() throws -> ScanResult {
        let rootPath = self.rootPath
        let started = Date()
        try Task.checkCancellation()
        guard !exclusions.contains(rootPath), !promptAvoidance.contains(rootPath), !isSensitivePath(root) else {
            let reason = exclusions.contains(rootPath) ? "excluded by folder settings" :
                promptAvoidance.contains(rootPath) ? "skipped to avoid a macOS permission prompt" : "excluded by sensitive path policy"
            recordSkip(path: rootPath, reason: reason)
            return ScanResult(rootPath: rootPath, nodes: [], started: started, elapsed: Date().timeIntervalSince(started), processDiskReadBytes: DiskReadMetric.bytesRead(from: diskReadStart, to: ProcessMemory.diskReadBytes()), skipped: skipped, incompleteEvidence: incompleteEvidence, incompleteEvidenceTruncated: incompleteEvidenceTruncated)
        }

        let rootInfo = try lstat(at: rootPath)
        rootDevice = UInt64(rootInfo.st_dev)
        let rootName = root.lastPathComponent.isEmpty ? rootPath : root.lastPathComponent
        let rootID = appendNode(parent: nil, metadata: metadata(from: rootInfo, name: rootName))
        reportProgress(path: rootPath)
        if isDirectory(rootInfo), !isSymlink(rootInfo) {
            try traverse(from: rootID, path: rootPath)
        }
        if backend == .parallel { try canonicalizeParallelNodes() }
        try aggregateDirectories()
        if backend == .parallel { refreshFinalLiveLocations() }
        reportProgress(path: rootPath, force: true)
        try cancellation.check()
        let elapsed = Date().timeIntervalSince(started)
        let result = ScanResult(
            rootPath: rootPath,
            nodes: nodes,
            started: started,
            elapsed: elapsed,
            processDiskReadBytes: DiskReadMetric.bytesRead(from: diskReadStart, to: ProcessMemory.diskReadBytes()),
            errors: errors,
            skipped: skipped,
            incompleteEvidence: incompleteEvidence,
            incompleteEvidenceTruncated: incompleteEvidenceTruncated
        )
        DiskScannerDiagnostics.shared.record(backendCounters)
        return result
    }

    private mutating func traverse(from rootID: Int, path rootPath: String) throws {
        if backend != .parallel {
            let reader = DirectoryReader(backend: backend, cancellation: cancellation)
            var directories = [ScanDirectory(id: rootID, path: rootPath, owner: nil)]
            while let directory = directories.popLast() {
                try cancellation.check()
                let result: Result<[EntryMetadata], Error> = Result {
                    try autoreleasepool {
                        var entries = try reader.childEntries(at: directory.path)
                        entries.sort { $0.name < $1.name }
                        return entries
                    }
                }
                directories.append(contentsOf: try consume(directory, result: result).reversed())
            }
            backendCounters = reader.backendCounters
            return
        }
        let workers: Int
        if parallelism > 0 { workers = parallelism }
        else {
            let parentDevice = try? lstat(at: root.deletingLastPathComponent().path).st_dev
            workers = DiskScanner.automaticParallelism(rootPath: rootPath, rootDevice: rootDevice,
                parentDevice: parentDevice.map(UInt64.init), processorCount: ProcessInfo.processInfo.activeProcessorCount)
        }
        let pool = DirectoryReadPool(workers: max(1, workers), backend: backend, cancellation: cancellation)
        defer { pool.stop() }
        pool.submit([ScanDirectory(id: rootID, path: rootPath, owner: nil)])
        var pending = 1
        while pending > 0 {
            try cancellation.check()
            let completed = pool.next()
            try cancellation.check()
            let children = try consume(completed.directory, result: completed.result)
            pending += children.count - 1
            pool.submit(children.reversed())
        }
        pool.stop()
        backendCounters = pool.counters()
    }

    private mutating func consume(_ directory: ScanDirectory, result: Result<[EntryMetadata], Error>) throws -> [ScanDirectory] {
        try autoreleasepool {
            let entries: [EntryMetadata]
            do { entries = try result.get() }
            catch is CancellationError { throw CancellationError() }
            catch {
                nodes[directory.id].isContentsUnreadable = true
                nodes[directory.id].isScanIncomplete = true
                recordSkip(path: directory.path, error: error)
                return []
            }
            nodes[directory.id].isContentsUnreadable = false
            nodes[directory.id].isScanIncomplete = false
            nodes[directory.id].children.reserveCapacity(entries.count)
            var childDirectories: [ScanDirectory] = []
            for (entryIndex, entry) in entries.enumerated() {
                if entryIndex & 255 == 0 { try cancellation.check() }
                if !exclusions.paths.isEmpty, exclusions.contains(childPath(directory.path, entry.name)) {
                    nodes[directory.id].isScanIncomplete = true
                    recordSkip(path: childPath(directory.path, entry.name), reason: "excluded by folder settings")
                    continue
                }
                if !promptAvoidance.paths.isEmpty, promptAvoidance.contains(childPath(directory.path, entry.name)) {
                    nodes[directory.id].isScanIncomplete = true
                    recordSkip(path: childPath(directory.path, entry.name), reason: "skipped to avoid a macOS permission prompt")
                    continue
                }
                guard !isSensitiveComponent(entry.name) else {
                    nodes[directory.id].isScanIncomplete = true
                    recordSkip(path: childPath(directory.path, entry.name), reason: "excluded by sensitive path policy")
                    continue
                }
                guard entry.device == rootDevice, !entry.isMountPoint else {
                    nodes[directory.id].isScanIncomplete = true
                    recordSkip(path: childPath(directory.path, entry.name), reason: "mount boundary (protected volume)")
                    continue
                }
                let childID = appendNode(parent: directory.id, metadata: entry, liveOwner: directory.owner)
                reportProgress(path: childPath(directory.path, entry.name))
                if entry.isDirectory, !entry.isSymlink {
                    childDirectories.append(ScanDirectory(id: childID, path: childPath(directory.path, entry.name), owner: directory.owner ?? childID))
                }
            }
            return childDirectories
        }
    }

    /// Parallel enumeration may finish siblings out of DFS order. Restore the
    /// reference scanner's exact IDs and allocation owners before publishing.
    /// One integer mapping is used; no second multi-million-node tree is copied.
    private mutating func canonicalizeParallelNodes() throws {
        if nodes.count <= UInt32.max { try canonicalizeParallelNodes(using: UInt32.self) }
        else { try canonicalizeParallelNodes(using: UInt64.self) }
    }

    private mutating func canonicalizeParallelNodes<Index: FixedWidthInteger & UnsignedInteger>(using: Index.Type) throws {
        guard !nodes.isEmpty else { return }
        var mapping = [Index](repeating: 0, count: nodes.count)
        var next = 1
        var directories = [0]
        while let directory = directories.popLast() {
            try cancellation.check()
            for child in nodes[directory].children {
                mapping[child] = Index(next)
                next += 1
            }
            for child in nodes[directory].children.reversed() where nodes[child].isDirectory && !nodes[child].isSymlink {
                directories.append(child)
            }
        }
        for id in nodes.indices {
            if id & 255 == 0 { try cancellation.check() }
            while Int(mapping[nodes[id].id]) != id {
                nodes.swapAt(id, Int(mapping[nodes[id].id]))
            }
        }
        for id in nodes.indices {
            if id & 255 == 0 { try cancellation.check() }
            nodes[id].id = id
            if let parent = nodes[id].parent { nodes[id].parent = Int(mapping[parent]) }
            for index in nodes[id].children.indices {
                nodes[id].children[index] = Int(mapping[nodes[id].children[index]])
            }
        }
        allocatedInodes.removeAll(keepingCapacity: true)
        for index in linkedAllocations.indices { linkedAllocations[index].id = Int(mapping[linkedAllocations[index].id]) }
        linkedAllocations.sort { $0.id < $1.id }
        for link in linkedAllocations {
            let identity = FileIdentity(device: nodes[link.id].device, inode: nodes[link.id].inode)
            nodes[link.id].allocatedBytes = allocatedInodes.insert(identity).inserted ? link.bytes : 0
        }
        linkedAllocations.removeAll(keepingCapacity: false)
    }

    private mutating func refreshFinalLiveLocations() {
        guard progress != nil, !nodes.isEmpty else { return }
        livePendingOwner = nil
        livePendingBytes = 0
        liveRootBytes.removeAll(keepingCapacity: true)
        liveLeaders = Array(nodes[0].children.sorted {
            nodes[$0].allocatedBytes == nodes[$1].allocatedBytes ? $0 < $1 : nodes[$0].allocatedBytes > nodes[$1].allocatedBytes
        }.prefix(8))
        for id in liveLeaders { liveRootBytes[id] = nodes[id].allocatedBytes }
        liveAllocated = nodes[0].allocatedBytes
        liveLogical = nodes[0].logicalBytes
    }

    private mutating func appendNode(parent: Int?, metadata: EntryMetadata, liveOwner: Int? = nil) -> Int {
        let identity = FileIdentity(device: metadata.device, inode: metadata.inode)
        let allocatedBytes: Int64
        if metadata.isDirectory || metadata.isSymlink || identity.inode == 0 {
            allocatedBytes = 0
        } else if metadata.linkCount == 1 {
            allocatedBytes = metadata.allocatedBytes
        } else if allocatedInodes.insert(identity).inserted {
            allocatedBytes = metadata.allocatedBytes
        } else {
            allocatedBytes = 0
        }

        let id = nodes.count
        if backend == .parallel, !metadata.isDirectory, !metadata.isSymlink, metadata.inode != 0, metadata.linkCount != 1 {
            linkedAllocations.append((id, metadata.allocatedBytes))
        }
        nodes.append(
            DiskNode(
                id: id,
                parent: parent,
                name: metadata.name,
                isDirectory: metadata.isDirectory,
                isSymlink: metadata.isSymlink,
                logicalBytes: metadata.logicalBytes,
                allocatedBytes: allocatedBytes,
                modified: metadata.modified,
                device: metadata.device,
                inode: metadata.inode
            )
        )
        if let parent { nodes[parent].children.append(id) }
        if progress != nil {
            let owner = liveOwner ?? id
            if !metadata.isDirectory, !metadata.isSymlink {
                liveFiles += 1
                liveAllocated = saturatingAdd(liveAllocated, allocatedBytes)
                liveLogical = saturatingAdd(liveLogical, metadata.logicalBytes)
                if livePendingOwner != owner {
                    flushLiveLocation()
                    livePendingOwner = owner
                }
                livePendingBytes = saturatingAdd(livePendingBytes, allocatedBytes)
            }
        }
        return id
    }

    /// Accumulate one location in registers, updating its dictionary/ranking
    /// only on an owner change or visible progress update.
    private mutating func flushLiveLocation() {
        guard let owner = livePendingOwner else { return }
        liveRootBytes[owner] = saturatingAdd(liveRootBytes[owner] ?? 0, livePendingBytes)
        livePendingBytes = 0
        livePendingOwner = nil
        var rank: Int
        if let existing = liveLeaders.firstIndex(of: owner) { rank = existing }
        else { liveLeaders.append(owner); rank = liveLeaders.count - 1 }
        while rank > 0 {
            let prior = liveLeaders[rank - 1]
            let currentBytes = liveRootBytes[owner] ?? 0
            let priorBytes = liveRootBytes[prior] ?? 0
            guard currentBytes > priorBytes || (currentBytes == priorBytes && owner < prior) else { break }
            liveLeaders.swapAt(rank, rank - 1)
            rank -= 1
        }
        if liveLeaders.count > 8 { liveLeaders.removeLast() }
    }

    private mutating func aggregateDirectories() throws {
        for id in nodes.indices.reversed() {
            if id & 255 == 0 { try Task.checkCancellation() }
            guard nodes[id].isDirectory else { continue }
            var logicalBytes: Int64 = 0
            var allocatedBytes: Int64 = 0
            for (index, child) in nodes[id].children.enumerated() {
                if index & 255 == 0 { try Task.checkCancellation() }
                logicalBytes = saturatingAdd(logicalBytes, nodes[child].logicalBytes)
                allocatedBytes = saturatingAdd(allocatedBytes, nodes[child].allocatedBytes)
                if nodes[child].isScanIncomplete == true { nodes[id].isScanIncomplete = true }
            }
            nodes[id].logicalBytes = logicalBytes
            nodes[id].allocatedBytes = allocatedBytes
        }
    }

    private mutating func reportProgress(path: @autoclosure () -> String, force: Bool = false) {
        let entryCount = nodes.count
        guard let progress, force || entryCount == 1 || entryCount % 128 == 0 else { return }
        let now = ContinuousClock.now
        guard force || lastProgress == nil || lastProgress!.duration(to: now) >= .milliseconds(100) else { return }
        flushLiveLocation()
        lastProgress = now
        let duration = liveStart.duration(to: now).components
        progress(ScanProgress(entries: entryCount, path: path(),
            allocatedBytes: liveAllocated, logicalBytes: liveLogical,
            files: liveFiles, skipped: skipped,
            elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
            processDiskReadBytes: DiskReadMetric.bytesRead(from: diskReadStart, to: ProcessMemory.diskReadBytes()),
            locations: liveLeaders.map { ScanLiveLocation(id: $0, name: nodes[$0].name, allocatedBytes: liveRootBytes[$0] ?? 0) }))
    }

    private mutating func recordSkip(path: String, error: Error) {
        skipped += 1
        recordEvidence(path: path, reason: "unreadable directory")
        guard errors.count < Self.maximumErrors else { return }
        errors.append("\(path): \(error.localizedDescription)")
    }

    private mutating func recordSkip(path: String, reason: String) {
        skipped += 1
        recordEvidence(path: path, reason: reason)
    }

    private mutating func recordEvidence(path: String, reason: String) {
        guard incompleteEvidence.count < Self.maximumIncompleteEvidence else {
            incompleteEvidenceTruncated = true
            return
        }
        incompleteEvidence.append(ScanIncompleteEvidence(path: path, reason: reason))
    }
}

private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

private struct ScanDirectory: Sendable {
    let id: Int
    let path: String
    let owner: Int?
}

private struct CompletedDirectory: Sendable {
    let directory: ScanDirectory
    let result: Result<[EntryMetadata], Error>
}

/// Fixed blocking readers overlap kernel I/O and parsing with result assembly.
/// A bounded completion queue applies backpressure; workers never mutate nodes.
private final class DirectoryReadPool: @unchecked Sendable {
    // Separate wait channels prevent one completed leaf from waking every
    // reader. Only the coordinator publishes jobs and consumes completions.
    private let jobLock = NSLock()
    private let jobsAvailable = DispatchSemaphore(value: 0)
    private let completionsAvailable = DispatchSemaphore(value: 0)
    private let readyCondition = NSCondition()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "StorageDaddy.metadata", qos: .userInitiated, attributes: .concurrent)
    private let readers: [DirectoryReader]
    private let maximumReady: Int
    private var jobs: [ScanDirectory] = []
    private var stoppingJobs = false
    private var ready: [CompletedDirectory] = []
    private var readyBytes = 0
    private let maximumReadyBytes = 4 * 1024 * 1024
    private var stoppingResults = false

    init(workers: Int, backend: ScanBackend, cancellation: ScanCancellation) {
        maximumReady = workers * 2
        readers = (0..<workers).map { _ in DirectoryReader(backend: backend, cancellation: cancellation) }
        for reader in readers {
            group.enter()
            queue.async { [self] in
                defer { group.leave() }
                while let job = pop() {
                    let result: Result<[EntryMetadata], Error> = Result {
                        try autoreleasepool {
                            try cancellation.check()
                            var entries = try reader.childEntries(at: job.path)
                            entries.sort { $0.name < $1.name }
                            return entries
                        }
                    }
                    let bytes = Self.estimatedBytes(result)
                    readyCondition.lock()
                    while !stoppingResults && (ready.count >= maximumReady || (!ready.isEmpty && readyBytes + bytes > maximumReadyBytes)) { readyCondition.wait() }
                    if stoppingResults {
                        readyCondition.unlock()
                        return
                    }
                    ready.append(CompletedDirectory(directory: job, result: result))
                    readyBytes += bytes
                    readyCondition.unlock()
                    completionsAvailable.signal()
                }
            }
        }
    }

    func submit<S: Collection>(_ directories: S) where S.Element == ScanDirectory {
        guard !directories.isEmpty else { return }
        jobLock.withLock { jobs.append(contentsOf: directories) }
        for _ in directories { jobsAvailable.signal() }
    }

    private func pop() -> ScanDirectory? {
        jobsAvailable.wait()
        return jobLock.withLock { stoppingJobs ? nil : jobs.popLast() }
    }

    func next() -> CompletedDirectory {
        completionsAvailable.wait()
        readyCondition.lock()
        let result = ready.removeLast()
        readyBytes -= Self.estimatedBytes(result.result)
        readyCondition.signal()
        readyCondition.unlock()
        return result
    }

    func stop() {
        jobLock.withLock {
            stoppingJobs = true
            jobs.removeAll(keepingCapacity: false)
        }
        readyCondition.lock()
        stoppingResults = true
        ready.removeAll(keepingCapacity: false)
        readyBytes = 0
        readyCondition.broadcast()
        readyCondition.unlock()
        for _ in readers { jobsAvailable.signal() }
        group.wait()
    }

    private static func estimatedBytes(_ result: Result<[EntryMetadata], Error>) -> Int {
        guard case .success(let entries) = result else { return 0 }
        return entries.capacity * MemoryLayout<EntryMetadata>.stride
    }

    func counters() -> DiskScannerBackendCounters {
        // Caller joins workers before reading their exclusively-owned counters.
        var result = DiskScannerBackendCounters()
        for reader in readers {
            result.bulkDirectories += reader.backendCounters.bulkDirectories
            result.foundationDirectories += reader.backendCounters.foundationDirectories
            result.bulkFallbacks += reader.backendCounters.bulkFallbacks
        }
        return result
    }
}

/// Each reader and its reusable scratch buffer have one worker owner.
private final class DirectoryReader: @unchecked Sendable {
    let backend: ScanBackend
    let cancellation: ScanCancellation
    var backendCounters = DiskScannerBackendCounters()
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    init(backend: ScanBackend, cancellation: ScanCancellation) {
        self.backend = backend
        self.cancellation = cancellation
    }

    func childEntries(at path: String) throws -> [EntryMetadata] {
        guard backend != .foundation else { return try foundationChildEntries(at: path) }
        do {
            let entries = try bulkChildEntries(at: path)
            backendCounters.bulkDirectories += 1
            return entries
        } catch is BulkFallback {
            // Only capability failures use Foundation. A malformed packed record
            // or a per-entry error remains observable as a skipped directory.
            backendCounters.bulkFallbacks += 1
            return try foundationChildEntries(at: path)
        }
    }

    private func foundationChildEntries(at path: String) throws -> [EntryMetadata] {
        backendCounters.foundationDirectories += 1
        return try FileManager.default.contentsOfDirectory(atPath: path).map { name in
            let childPath = (path as NSString).appendingPathComponent(name)
            return metadata(from: try lstat(at: childPath), name: name)
        }
    }

    /// `getattrlistbulk` vends each entry's metadata in a packed buffer. This
    /// primary path avoids a metadata syscall per file; `lstat` is retained for
    /// the selected root and the Foundation fallback only.
    private func bulkChildEntries(at path: String) throws -> [EntryMetadata] {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let code = errno
            if supportsFoundationFallback(code) { throw BulkFallback.unavailable }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
            | UInt32(ATTR_CMN_ERROR)
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_DEVID)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_MODTIME)
            | UInt32(ATTR_CMN_FILEID)
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_DATALENGTH) | UInt32(ATTR_FILE_DATAALLOCSIZE)

        var entries: [EntryMetadata] = []
        while true {
            try cancellation.check()
            let count: Int32 = buffer.withUnsafeMutableBytes { bytes in
                getattrlistbulk(descriptor, &attributes, bytes.baseAddress, bytes.count, 0)
            }
            if count < 0 {
                let code = errno
                if supportsFoundationFallback(code) { throw BulkFallback.unavailable }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard count > 0 else { break }
            try buffer.withUnsafeBytes { rawBytes in
                try parseBulkEntries(from: rawBytes, count: Int(count), into: &entries)
            }
        }
        return entries
    }

    private func parseBulkEntries(from bytes: UnsafeRawBufferPointer, count: Int, into entries: inout [EntryMetadata]) throws {
        var offset = 0
        for index in 0 ..< count {
            if index & 255 == 0 { try cancellation.check() }
            guard offset + MemoryLayout<UInt32>.size <= bytes.count else {
                throw ScannerFailure.malformedBulkRecord
            }
            let recordLength = Int(try read(UInt32.self, from: bytes, at: offset, through: bytes.count))
            let recordEnd = offset + recordLength
            let returnedOffset = offset + MemoryLayout<UInt32>.size
            var cursor = returnedOffset + MemoryLayout<attribute_set_t>.size
            guard recordLength > 0, recordEnd <= bytes.count, cursor <= recordEnd else {
                throw ScannerFailure.malformedBulkRecord
            }

            let returned = try read(attribute_set_t.self, from: bytes, at: returnedOffset, through: recordEnd)
            // ATTR_CMN_ERROR is packed directly after RETURNED_ATTRS only when
            // an entry reports an error. Successful records omit it.
            if has(returned.commonattr, ATTR_CMN_ERROR) {
                let entryError = try read(UInt32.self, from: bytes, at: cursor, through: recordEnd)
                cursor += MemoryLayout<UInt32>.size
                guard entryError == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: Int32(bitPattern: entryError)) ?? .EIO)
                }
            }
            guard has(returned.commonattr, ATTR_CMN_NAME),
                  has(returned.commonattr, ATTR_CMN_DEVID),
                  has(returned.commonattr, ATTR_CMN_OBJTYPE),
                  has(returned.commonattr, ATTR_CMN_MODTIME),
                  has(returned.commonattr, ATTR_CMN_FILEID) else {
                throw BulkFallback.missingMetadata
            }

            let reference = try read(attrreference_t.self, from: bytes, at: cursor, through: recordEnd)
            let referenceOffset = cursor
            cursor += MemoryLayout<attrreference_t>.size
            let nameOffset = referenceOffset + Int(reference.attr_dataoffset)
            let nameLength = Int(reference.attr_length)
            guard nameLength > 0, nameOffset >= offset, nameOffset <= recordEnd - nameLength else {
                throw ScannerFailure.malformedBulkRecord
            }
            let nameBytes = bytes[nameOffset ..< nameOffset + nameLength].bindMemory(to: UInt8.self)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            guard !name.isEmpty, name != ".", name != ".." else {
                offset = recordEnd
                continue
            }

            let device = UInt64(try read(dev_t.self, from: bytes, at: cursor, through: recordEnd))
            cursor += MemoryLayout<dev_t>.size
            let objectType = try read(fsobj_type_t.self, from: bytes, at: cursor, through: recordEnd)
            cursor += MemoryLayout<fsobj_type_t>.size
            let modified = try read(timespec.self, from: bytes, at: cursor, through: recordEnd)
            cursor += MemoryLayout<timespec>.size
            let inode = try read(UInt64.self, from: bytes, at: cursor, through: recordEnd)
            cursor += MemoryLayout<UInt64>.size

            let directory = UInt32(objectType) == UInt32(VDIR.rawValue)
            let symlink = UInt32(objectType) == UInt32(VLNK.rawValue)
            var mountPoint = false
            if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
                let status = try read(UInt32.self, from: bytes, at: cursor, through: recordEnd)
                cursor += MemoryLayout<UInt32>.size
                mountPoint = status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            } else if directory {
                throw BulkFallback.missingMetadata
            }

            // Unknown link counts conservatively retain identity tracking.
            var linkCount: UInt32 = 2
            if has(returned.fileattr, ATTR_FILE_LINKCOUNT) {
                linkCount = try read(UInt32.self, from: bytes, at: cursor, through: recordEnd)
                cursor += MemoryLayout<UInt32>.size
            }
            var logicalBytes: Int64 = 0
            var allocatedBytes: Int64 = 0
            if has(returned.fileattr, ATTR_FILE_DATALENGTH) {
                logicalBytes = max(0, Int64(try read(off_t.self, from: bytes, at: cursor, through: recordEnd)))
                cursor += MemoryLayout<off_t>.size
            }
            if has(returned.fileattr, ATTR_FILE_DATAALLOCSIZE) {
                allocatedBytes = max(0, Int64(try read(off_t.self, from: bytes, at: cursor, through: recordEnd)))
            }
            if !directory, !symlink,
               (!has(returned.fileattr, ATTR_FILE_DATALENGTH) || !has(returned.fileattr, ATTR_FILE_DATAALLOCSIZE)) {
                throw BulkFallback.missingMetadata
            }

            entries.append(
                EntryMetadata(
                    name: name,
                    isDirectory: directory,
                    isSymlink: symlink,
                    logicalBytes: directory || symlink ? 0 : logicalBytes,
                    allocatedBytes: directory || symlink ? 0 : allocatedBytes,
                    modified: date(from: modified),
                    device: device,
                    inode: inode,
                    linkCount: linkCount,
                    isMountPoint: mountPoint
                )
            )
            offset = recordEnd
        }
    }

}

private func childPath(_ directory: String, _ name: String) -> String {
    directory == "/" ? "/" + name : directory + "/" + name
}

private struct EntryMetadata: Sendable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let modified: Date
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt32
    let isMountPoint: Bool
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

private enum BulkFallback: Error {
    case unavailable
    case missingMetadata
}

private enum ScannerFailure: LocalizedError {
    case malformedBulkRecord

    var errorDescription: String? {
        "getattrlistbulk returned a malformed directory record"
    }
}

/// Internal test instrumentation. It is deliberately absent from the public API.
enum DiskScannerDiagnostics {
    static let shared = DiskScannerDiagnosticsStore()
}

struct DiskScannerBackendCounters: Sendable, Equatable {
    var bulkDirectories = 0
    var foundationDirectories = 0
    var bulkFallbacks = 0
}

final class DiskScannerDiagnosticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bulkDirectories = 0
    private var foundationDirectories = 0
    private var bulkFallbacks = 0

    func reset() {
        lock.withLock { bulkDirectories = 0; foundationDirectories = 0; bulkFallbacks = 0 }
    }

    func snapshot() -> DiskScannerBackendCounters {
        lock.withLock {
            DiskScannerBackendCounters(
                bulkDirectories: bulkDirectories,
                foundationDirectories: foundationDirectories,
                bulkFallbacks: bulkFallbacks
            )
        }
    }

    func record(_ counters: DiskScannerBackendCounters) {
        lock.withLock {
            bulkDirectories += counters.bulkDirectories
            foundationDirectories += counters.foundationDirectories
            bulkFallbacks += counters.bulkFallbacks
        }
    }
}

private func metadata(from info: stat, name: String) -> EntryMetadata {
    let directory = isDirectory(info)
    let symlink = isSymlink(info)
    return EntryMetadata(
        name: name,
        isDirectory: directory,
        isSymlink: symlink,
        logicalBytes: directory || symlink ? 0 : max(0, Int64(info.st_size)),
        allocatedBytes: directory || symlink ? 0 : allocatedSize(for: info),
        modified: modificationDate(for: info),
        device: UInt64(info.st_dev),
        inode: UInt64(info.st_ino),
        linkCount: UInt32(info.st_nlink),
        isMountPoint: false
    )
}

private func read<T>(_ type: T.Type, from bytes: UnsafeRawBufferPointer, at offset: Int, through end: Int) throws -> T {
    guard offset >= 0, offset <= end - MemoryLayout<T>.size else {
        throw ScannerFailure.malformedBulkRecord
    }
    return bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
}

private func has(_ attributes: UInt32, _ attribute: Int32) -> Bool {
    attributes & UInt32(bitPattern: attribute) != 0
}

private func supportsFoundationFallback(_ code: Int32) -> Bool {
    code == ENOTSUP || code == ENOSYS
}

private func lstat(at path: String) throws -> stat {
    var info = stat()
    guard Darwin.lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return info
}

private func isDirectory(_ info: stat) -> Bool {
    (info.st_mode & S_IFMT) == S_IFDIR
}

private func isSymlink(_ info: stat) -> Bool {
    (info.st_mode & S_IFMT) == S_IFLNK
}

private func allocatedSize(for info: stat) -> Int64 {
    let (value, overflow) = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
    return overflow ? Int64.max : max(0, value)
}

private func modificationDate(for info: stat) -> Date {
    #if os(macOS)
    let timestamp = info.st_mtimespec
    #else
    let timestamp = info.st_mtim
    #endif
    return date(from: timestamp)
}

private func date(from timestamp: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(timestamp.tv_sec) + TimeInterval(timestamp.tv_nsec) / 1_000_000_000)
}

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : value
}

private func isSensitivePath(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    return [standardized, canonical].contains { candidate in
        candidate.path.split(separator: "/").contains { isSensitiveComponent(String($0)) }
    }
}

private func isSensitiveComponent(_ name: String) -> Bool {
    // Most entries cannot match any sensitive prefix. Avoid allocating a
    // lowercased copy of every ordinary filename on multi-million-entry scans.
    if let first = name.utf8.first, first < 128,
       first != 46, first != 67, first != 99, first != 83, first != 115 { return false }
    let normalized = name.lowercased()
    if normalized.hasPrefix(".env") { return true }
    if [".ssh", ".aws", ".kube", ".gnupg"].contains(normalized) { return true }
    for stem in ["credential", "credentials", "secret", "secrets"] {
        if normalized == stem || normalized.hasPrefix("\(stem).") { return true }
    }
    return false
}
