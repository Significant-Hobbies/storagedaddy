import Darwin
import Foundation

public struct LiveRemovalTotals: Codable, Sendable, Equatable {
    public var files: Int = 0
    public var sizeBytes: Int64 = 0
    public var freesBytes: Int64 = 0
    public var heldElsewhereBytes: Int64 = 0
    public var uncertainBytes: Int64 = 0
    public init() {}
}

public struct LiveRemovalPath: Codable, Sendable {
    public let path: String
    public let kind: String
    public let totals: LiveRemovalTotals
}
public struct LiveRemovalNestedPath: Codable, Sendable, Equatable {
    public let path: String
    public let within: String
}
public struct LiveRemovalReport: Codable, Sendable {
    public let measuredAt: Date
    public let elapsed: Double
    public let paths: [LiveRemovalPath]
    public let total: LiveRemovalTotals
    public let missing: [String]
    public let nested: [LiveRemovalNestedPath]
    public let skippedEntries: Int
    public let cloneMetadata: Bool
    public let incomplete: Bool
    public let warning: String
}

/// One observed regular-file name. Full-clone reference counts include members
/// outside the selected paths, so no unrelated directory or file need be read.
public struct LiveRemovalFact: Sendable, Equatable {
    public enum Sharing: Sendable, Equatable { case unshared, shared, unavailable }
    public let pathIndex: Int
    public let device: UInt64
    public let inode: UInt64
    public let allocatedBytes: Int64
    public let linkCount: UInt32
    public let privateBytes: Int64?
    public let sharing: Sharing
    public let cloneVolumeID: UInt64?
    public let cloneID: UInt64?
    public let cloneReferenceCount: UInt32?
    public init(pathIndex: Int, device: UInt64, inode: UInt64, allocatedBytes: Int64, linkCount: UInt32 = 1,
                privateBytes: Int64? = nil, sharing: Sharing = .unshared,
                cloneVolumeID: UInt64? = nil, cloneID: UInt64? = nil, cloneReferenceCount: UInt32? = nil) {
        self.pathIndex = pathIndex; self.device = device; self.inode = inode; self.allocatedBytes = allocatedBytes
        self.linkCount = linkCount; self.privateBytes = privateBytes; self.sharing = sharing
        self.cloneVolumeID = cloneVolumeID; self.cloneID = cloneID; self.cloneReferenceCount = cloneReferenceCount
    }
}

/// Streaming allocation reducer. Ordinary files need no retained record. Only
/// hardlinked inodes and clone groups occupy the bounded exceptional maps.
public struct LiveRemovalAccumulator: Sendable {
    private struct Identity: Hashable, Sendable { let device: UInt64; let inode: UInt64 }
    private struct Linked: Sendable {
        var fact: LiveRemovalFact
        var namesByPath: [Int: Int] = [:]
        var names = 0
        var stable = true
    }
    private struct CloneGroup: Sendable {
        var references: UInt32
        var bytes: Int64
        var membersRemoved = 0
        var removedByPath: [Int: Int] = [:]
        var holdingPaths = Set<Int>()
    }
    private var paths: [LiveRemovalTotals]
    private var total = LiveRemovalTotals()
    private var links: [Identity: Linked] = [:]
    private var groups: [Identity: CloneGroup] = [:]
    private let maximumTracked: Int
    private var finished = false
    public private(set) var incomplete = false
    public init(pathCount: Int, maximumTracked: Int = 500_000) {
        paths = Array(repeating: LiveRemovalTotals(), count: max(0, pathCount)); self.maximumTracked = max(1, maximumTracked)
    }
    public mutating func add(_ fact: LiveRemovalFact) throws {
        guard !finished, paths.indices.contains(fact.pathIndex), fact.allocatedBytes >= 0, fact.linkCount > 0 else {
            throw RemovalMeasurement.failure("Invalid live allocation metadata.")
        }
        total.files += 1; paths[fact.pathIndex].files += 1
        if fact.linkCount > 1 {
            let key = Identity(device: fact.device, inode: fact.inode)
            if links[key] == nil {
                guard links.count + groups.count < maximumTracked else { throw RemovalMeasurement.failure("Too many shared identities. Measure a smaller selection.") }
                links[key] = Linked(fact: fact)
            }
            var link = links[key]!
            let original = link.fact
            if original.linkCount != fact.linkCount || original.allocatedBytes != fact.allocatedBytes ||
                original.privateBytes != fact.privateBytes || original.sharing != fact.sharing ||
                original.cloneVolumeID != fact.cloneVolumeID || original.cloneID != fact.cloneID ||
                original.cloneReferenceCount != fact.cloneReferenceCount { link.stable = false; incomplete = true }
            link.names += 1; link.namesByPath[fact.pathIndex, default: 0] += 1
            links[key] = link
        } else {
            addSize(fact.allocatedBytes, holders: [fact.pathIndex])
            try member(fact, removedTogether: true, holders: [fact.pathIndex: true])
        }
    }
    public mutating func finish() throws -> (paths: [LiveRemovalTotals], total: LiveRemovalTotals) {
        guard !finished else { throw RemovalMeasurement.failure("The allocation measurement has already finished.") }
        let linked = links; links = [:]
        for link in linked.values {
            addSize(link.fact.allocatedBytes, holders: Array(link.namesByPath.keys))
            let complete = link.stable && link.names == Int(link.fact.linkCount)
            let holders = link.namesByPath.mapValues { link.stable && $0 == Int(link.fact.linkCount) }
            if !link.stable {
                account(removedTogether: false, holders: holders, own: 0, uncertain: link.fact.allocatedBytes)
            } else { try member(link.fact, removedTogether: complete, holders: holders) }
        }
        for group in groups.values {
            if group.membersRemoved >= Int(group.references) { total.freesBytes = sum(total.freesBytes, group.bytes) }
            else { total.heldElsewhereBytes = sum(total.heldElsewhereBytes, group.bytes) }
            for path in group.holdingPaths {
                if group.removedByPath[path, default: 0] >= Int(group.references) { paths[path].freesBytes = sum(paths[path].freesBytes, group.bytes) }
                else { paths[path].heldElsewhereBytes = sum(paths[path].heldElsewhereBytes, group.bytes) }
            }
        }
        groups = [:]; finished = true
        return (paths, total)
    }
    private mutating func addSize(_ bytes: Int64, holders: [Int]) {
        total.sizeBytes = sum(total.sizeBytes, bytes)
        for path in holders { paths[path].sizeBytes = sum(paths[path].sizeBytes, bytes) }
    }
    private mutating func member(_ fact: LiveRemovalFact, removedTogether: Bool, holders: [Int: Bool]) throws {
        let privateBytes = fact.privateBytes.map { min(fact.allocatedBytes, max(0, $0)) }
        switch fact.sharing {
        case .unshared:
            let own = privateBytes ?? fact.allocatedBytes
            account(removedTogether: removedTogether, holders: holders, own: own, uncertain: fact.allocatedBytes - own)
        case .unavailable:
            let own = privateBytes ?? 0
            account(removedTogether: removedTogether, holders: holders, own: own, uncertain: fact.allocatedBytes - own)
        case .shared:
            let own = privateBytes ?? 0, shared = fact.allocatedBytes - own
            guard let volume = fact.cloneVolumeID, volume != 0, let clone = fact.cloneID, clone != 0,
                  let references = fact.cloneReferenceCount, references >= 2 else {
                account(removedTogether: removedTogether, holders: holders, own: own, uncertain: shared); return
            }
            account(removedTogether: removedTogether, holders: holders, own: own, uncertain: 0)
            let key = Identity(device: volume, inode: clone)
            if groups[key] == nil {
                guard links.count + groups.count < maximumTracked else { throw RemovalMeasurement.failure("Too many clone groups. Measure a smaller selection.") }
                groups[key] = CloneGroup(references: references, bytes: shared)
            }
            var group = groups[key]!
            group.references = max(group.references, references); group.bytes = max(group.bytes, shared)
            if removedTogether { group.membersRemoved += 1 }
            for (path, alone) in holders {
                group.holdingPaths.insert(path)
                if alone { group.removedByPath[path, default: 0] += 1 }
            }
            groups[key] = group
        }
    }
    private mutating func account(removedTogether: Bool, holders: [Int: Bool], own: Int64, uncertain: Int64) {
        if removedTogether {
            total.freesBytes = sum(total.freesBytes, own); total.uncertainBytes = sum(total.uncertainBytes, uncertain)
        } else { total.heldElsewhereBytes = sum(total.heldElsewhereBytes, sum(own, uncertain)) }
        for (path, alone) in holders {
            if alone { paths[path].freesBytes = sum(paths[path].freesBytes, own); paths[path].uncertainBytes = sum(paths[path].uncertainBytes, uncertain) }
            else { paths[path].heldElsewhereBytes = sum(paths[path].heldElsewhereBytes, sum(own, uncertain)) }
        }
    }
    private mutating func sum(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        if overflow { incomplete = true; return .max }
        return value
    }
}

/// Independent native implementation using Apple's extended allocation attrs.
/// Reads metadata only. No content hashes, hydration, deletion or global walk.
public enum RemovalMeasurement {
    public static func measure(paths: [URL], excludedFolders: [String] = [], maximumEntries: Int = 5_000_000,
        cancellationCheck: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> LiveRemovalReport {
        guard !paths.isEmpty, paths.count <= 20, maximumEntries > 0,
              paths.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) }) else {
            throw failure("Choose 1–20 absolute local file or folder paths.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let normalized = Array(Set(paths.map { url -> String in
            let value = url.standardizedFileURL
            return value.path == "/" ? "/" : value.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(value.lastPathComponent).path
        })).sorted()
        var roots: [String] = [], nested: [LiveRemovalNestedPath] = []
        for path in normalized {
            if let parent = roots.last(where: { $0 == "/" ? path != "/" : path.hasPrefix($0 + "/") }) {
                nested.append(LiveRemovalNestedPath(path: path, within: parent))
            } else { roots.append(path) }
        }
        var worker = MeasurementWalk(roots: roots, excluded: FolderExclusions(paths: excludedFolders),
            maximumEntries: maximumEntries, cancellationCheck: cancellationCheck)
        try worker.run()
        let result = try worker.accumulator.finish()
        return LiveRemovalReport(measuredAt: Date(), elapsed: ProcessInfo.processInfo.systemUptime - started,
            paths: roots.enumerated().map { LiveRemovalPath(path: $0.element, kind: worker.kinds[$0.offset], totals: result.paths[$0.offset]) },
            total: result.total, missing: worker.missing, nested: nested, skippedEntries: worker.skipped,
            cloneMetadata: worker.cloneMetadata, incomplete: worker.skipped > 0 || worker.accumulator.incomplete || !worker.missing.isEmpty,
            warning: "Live file-allocation metadata estimate. Full-clone reference counts include copies outside this selection and scan; hard-link names count once. Modified clones with unidentified shared blocks remain uncertain. Local snapshots, open handles, directory metadata, concurrent writes and Trash can change actual volume space reclaimed; no files were removed.")
    }
    fileprivate static func failure(_ text: String) -> NSError { NSError(domain: "RemovalMeasurement", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

private struct MeasurementWalk {
    let roots: [String]
    let excluded: FolderExclusions
    let maximumEntries: Int
    let cancellationCheck: @Sendable () throws -> Void
    var accumulator: LiveRemovalAccumulator
    var kinds: [String]
    var missing: [String] = []
    var skipped = 0
    var seen = 0
    var cloneMetadata = false
    init(roots: [String], excluded: FolderExclusions, maximumEntries: Int, cancellationCheck: @escaping @Sendable () throws -> Void) {
        self.roots = roots; self.excluded = excluded; self.maximumEntries = maximumEntries; self.cancellationCheck = cancellationCheck
        accumulator = LiveRemovalAccumulator(pathCount: roots.count); kinds = Array(repeating: "unavailable", count: roots.count)
    }
    mutating func run() throws {
        for (owner, path) in roots.enumerated() {
            try cancellationCheck()
            guard !excluded.contains(path), !isSensitivePath(URL(fileURLWithPath: path)) else { skipped += 1; continue }
            var before = stat()
            guard lstat(path, &before) == 0 else { if errno == ENOENT { missing.append(path) } else { skipped += 1 }; continue }
            let kind = before.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else { skipped += 1; continue }
            let directory = kind == mode_t(S_IFDIR)
            let descriptor = open(path, (directory ? O_RDONLY | O_DIRECTORY : O_EVTONLY) | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { skipped += 1; continue }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, sameIdentity(before, opened) else { skipped += 1; continue }
            kinds[owner] = directory ? "folder" : "file"
            if directory { try directoryWalk(descriptor, path: path, device: opened.st_dev, owner: owner, depth: 0) }
            else { try file(descriptor, before: opened, owner: owner) }
        }
    }
    private mutating func step() throws {
        try cancellationCheck(); seen += 1
        guard seen <= maximumEntries else { throw RemovalMeasurement.failure("The live measurement exceeded its entry limit. Choose fewer paths.") }
    }
    private mutating func directoryWalk(_ descriptor: Int32, path: String, device: dev_t, owner: Int, depth: Int) throws {
        try step()
        guard depth < 128 else { skipped += 1; return }
        let copy = dup(descriptor)
        guard copy >= 0 else { skipped += 1; return }
        guard let stream = fdopendir(copy) else { close(copy); skipped += 1; return }
        defer { closedir(stream) }
        var baseline = stat(); _ = fstat(descriptor, &baseline)
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { skipped += 1 }; break }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try step()
            let child = path == "/" ? "/" + name : path + "/" + name
            guard !excluded.contains(child), !isSensitiveComponent(name) else { skipped += 1; continue }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { skipped += 1; continue }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR), metadata.st_dev == device else { skipped += 1; continue }
            let directory = kind == mode_t(S_IFDIR)
            let fd = openat(descriptor, name, (directory ? O_RDONLY | O_DIRECTORY : O_EVTONLY) | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { skipped += 1; continue }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, sameIdentity(metadata, opened) else { skipped += 1; continue }
            if directory { try directoryWalk(fd, path: child, device: device, owner: owner, depth: depth + 1) }
            else { try file(fd, before: opened, owner: owner) }
        }
        var after = stat()
        if fstat(descriptor, &after) != 0 || !sameIdentity(baseline, after) ||
            !sameTime(baseline.st_mtimespec, after.st_mtimespec) || !sameTime(baseline.st_ctimespec, after.st_ctimespec) { skipped += 1 }
    }
    private mutating func file(_ descriptor: Int32, before: stat, owner: Int) throws {
        var filesystem = statfs()
        let apfs = fstatfs(descriptor, &filesystem) == 0 && withUnsafePointer(to: filesystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) == "apfs" }
        }
        let attrs = apfs ? LiveAPFSAttributes.read(descriptor, expected: before) : nil
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameIdentity(before, after), before.st_size == after.st_size,
              before.st_nlink == after.st_nlink, sameTime(before.st_mtimespec, after.st_mtimespec),
              sameTime(before.st_ctimespec, after.st_ctimespec) else { skipped += 1; return }
        let allocation = Int64(before.st_blocks).multipliedReportingOverflow(by: 512)
        guard !allocation.overflow, allocation.partialValue >= 0, before.st_nlink > 0 else { skipped += 1; return }
        cloneMetadata = cloneMetadata || attrs != nil
        try accumulator.add(LiveRemovalFact(pathIndex: owner, device: UInt64(UInt32(bitPattern: before.st_dev)), inode: UInt64(before.st_ino),
            allocatedBytes: allocation.partialValue, linkCount: UInt32(before.st_nlink), privateBytes: attrs?.privateBytes,
            sharing: apfs ? attrs.map { $0.mayShare ? .shared : .unshared } ?? .unavailable : .unshared,
            cloneVolumeID: attrs?.volume, cloneID: attrs?.cloneID, cloneReferenceCount: attrs?.references))
    }
    private func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & mode_t(S_IFMT)) == (b.st_mode & mode_t(S_IFMT))
    }
    private func sameTime(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
}

private struct LiveAPFSAttributes {
    let privateBytes: Int64?
    let volume: UInt64?
    let cloneID: UInt64?
    let references: UInt32?
    let mayShare: Bool
    static func read(_ descriptor: Int32, expected: stat) -> Self? {
        // ABI-stable bits also work when building against an older SDK.
        let privateSize: UInt32 = 0x8, realDevice: UInt32 = 0x40, cloneID: UInt32 = 0x100
        let flags: UInt32 = 0x200, references: UInt32 = 0x1000
        let masks = [privateSize | realDevice | cloneID | flags | references,
                     privateSize | realDevice | cloneID | flags, privateSize | flags]
        for mask in masks {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_FILEID)
            attributes.forkattr = mask
            var buffer = [UInt8](repeating: 0, count: 128)
            let rc = buffer.withUnsafeMutableBytes { raw in
                fgetattrlist(descriptor, &attributes, raw.baseAddress, raw.count,
                    UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS))
            }
            if rc != 0 { if errno == EINVAL { continue }; return nil }
            return buffer.withUnsafeBytes { raw in
                guard let length: UInt32 = value(raw, 0), Int(length) <= raw.count,
                      let returned: attribute_set_t = value(raw, 4),
                      returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0,
                      returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0,
                      let device: dev_t = value(raw, 24), let inode: UInt64 = value(raw, 28),
                      device == expected.st_dev, inode == UInt64(expected.st_ino) else { return nil }
                var cursor = 36
                func field<T>(_ bit: UInt32, _: T.Type) -> T? {
                    guard mask & bit != 0 else { return nil }
                    defer { cursor += MemoryLayout<T>.size }
                    return returned.forkattr & bit != 0 ? value(raw, cursor) : nil
                }
                let privateBytes = field(privateSize, Int64.self)
                let real = field(realDevice, dev_t.self)
                let clone = field(cloneID, UInt64.self)
                let ext = field(flags, UInt64.self)
                let count = field(references, UInt32.self)
                guard let ext else { return nil }
                return Self(privateBytes: privateBytes.map { max(0, $0) }, volume: real.map { UInt64(UInt32(bitPattern: $0)) },
                    cloneID: clone, references: count, mayShare: ext & 0x41 != 0)
            }
        }
        return nil
    }
    private static func value<T>(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= buffer.count else { return nil }
        return buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
}
