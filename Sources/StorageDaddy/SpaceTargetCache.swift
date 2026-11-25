import Darwin
import DiskCore
import Foundation

/// Only include bounded, manager-owned download caches in automatic target selection.
struct SpaceTargetCache: Sendable {
    let tool: PackageCacheTool
    let executable: URL
    let home: URL
    let directory: URL
    let measured: URL
    let device: UInt64
    let inode: UInt64
    let bytes: Int64
    let exclusions: [String]

    var deferredReason: String? = nil

    var displayName: String {
        switch tool {
        case .lume: return "Lume downloaded VM images"
        case .pnpm: return "pnpm unreferenced packages"
        case .go: return "Go build cache"
        default: return tool.title + " package cache"
        }
    }

    static func discover(home: URL, exclusions: [String]) throws -> [Self] {
        var result: [Self] = []
        for (tool, paths): (PackageCacheTool, [String]) in [(.go, ["Library/Caches/go-build"]), (.npm, [".npm"]), (.pip, ["Library/Caches/pip", ".cache/pip"]), (.uv, [".cache/uv", "Library/Caches/uv"])] {
            try Task.checkCancellation()
            let expected = paths
                .map { home.appendingPathComponent($0).standardizedFileURL }
            guard expected.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let executable = tool.executable(home: home),
                  let directory = try? tool.cacheDirectory(executable: executable, home: home),
                  expected.contains(where: { $0.path == directory.path }),
                  directory.path == directory.resolvingSymlinksInPath().path,
                  !FolderExclusions(paths: exclusions).blocksCleanup(directory) else { continue }
            let measured = tool == .npm ? directory.appendingPathComponent("_cacache") : directory
            guard let identity = identity(measured) else { continue }
            if tool == .uv, let reason = lockReason(tool: tool, directory: directory) {
                result.append(Self(tool: tool, executable: executable, home: home, directory: directory,
                                   measured: measured, device: identity.0, inode: identity.1, bytes: 0,
                                   exclusions: exclusions, deferredReason: reason))
                continue
            }
            guard let bytes = try? allocatedBytes(in: measured, home: home), bytes > 0 else { continue }
            result.append(Self(tool: tool, executable: executable, home: home, directory: directory,
                               measured: measured, device: identity.0, inode: identity.1, bytes: bytes,
                               exclusions: exclusions))
        }
        return result
    }

    /// These stores can contain hundreds of thousands of entries. Their review is
    /// published independently from the small managers that populate the first screen.
    static func discoverManagedStores(home: URL, exclusions: [String]) throws -> [Self] {
        var result: [Self] = []
        let policy = FolderExclusions(paths: exclusions)
        for (tool, relative): (PackageCacheTool, String) in [(.lume, ".lume/cache"), (.pnpm, "Library/pnpm/store")] {
            try Task.checkCancellation()
            let base = home.appendingPathComponent(relative).standardizedFileURL
            guard identity(base) != nil, !policy.contains(base.path),
                  let executable = tool.executable(home: home),
                  let directory = try? tool.cacheDirectory(executable: executable, home: home),
                  directory.path == directory.resolvingSymlinksInPath().path, !policy.blocksCleanup(directory),
                  let identity = identity(directory) else { continue }
            let bytes: Int64
            if tool == .pnpm {
                guard directory.path.hasPrefix(base.path + "/"), directory.lastPathComponent == "v10",
                      let allocation = try? unreferencedPnpmBytes(in: directory) else { continue }
                bytes = allocation
            } else {
                guard directory.path == base.path,
                      let children = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                      children.contains("ghcr"), Set(children).isSubset(of: ["ghcr", ".DS_Store"]),
                      Self.identity(directory.appendingPathComponent("ghcr")) != nil,
                      let allocation = try? allocatedBytes(in: directory, home: home) else { continue }
                bytes = allocation
            }
            guard bytes > 0 else { continue }
            var reason: String?
            do { try CleanupActiveUse.validateCacheIsIdle(directory) }
            catch { reason = error.localizedDescription }
            result.append(Self(tool: tool, executable: executable, home: home, directory: directory,
                               measured: directory, device: identity.0, inode: identity.1, bytes: bytes,
                               exclusions: exclusions, deferredReason: reason))
        }
        try Task.checkCancellation()
        return result
    }

    private static func allocatedBytes(in directory: URL, home: URL) throws -> Int64 {
        let report = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/du"),
            arguments: ["-skx", directory.path], directory: home, timeout: 120)
        guard report.status == 0, let first = report.output.split(whereSeparator: { $0.isWhitespace }).first,
              let kib = Int64(first), kib >= 0, kib <= Int64.max / 1024 else { throw CocoaError(.fileReadUnknown) }
        return kib * 1024
    }

    /// pnpm v10 prunes single-link blobs in files/<two hex digits>/. Do not include
    /// linked project files, index metadata, or the total size of the store.
    private static func unreferencedPnpmBytes(in store: URL) throws -> Int64 {
        let fm = FileManager.default
        let files = store.appendingPathComponent("files")
        guard let root = identity(files), root.0 == identity(store)?.0 else { return 0 }
        var total: Int64 = 0
        for bucket in try fm.contentsOfDirectory(atPath: files.path) {
            try Task.checkCancellation()
            guard bucket.utf8.count == 2, bucket.allSatisfy(\.isHexDigit) else { continue }
            let dir = files.appendingPathComponent(bucket)
            guard identity(dir)?.0 == root.0 else { continue }
            for name in try fm.contentsOfDirectory(atPath: dir.path) {
                try Task.checkCancellation()
                let hash = name.hasSuffix("-exec") ? name.dropLast(5) : name[...]
                guard hash.utf8.count == 126, hash.allSatisfy(\.isHexDigit) else { continue }
                var metadata = stat()
                guard lstat(dir.appendingPathComponent(name).path, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { continue }
                total += Int64(metadata.st_blocks) * 512
            }
        }
        return total
    }

    /// Probe uv's existing advisory lock without creating or changing the lock file.
    /// The manager still owns locking when it runs after this point-in-time check.
    var lockReason: String? { deferredReason ?? Self.lockReason(tool: tool, directory: directory) }

    private static func lockReason(tool: PackageCacheTool, directory: URL) -> String? {
        if tool == .go || tool == .pip {
            do { try CleanupActiveUse.validateCacheIsIdle(directory); return nil }
            catch { return error.localizedDescription }
        }
        guard tool == .uv else { return nil }
        let path = directory.appendingPathComponent(".lock").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        let unavailable = "Could not verify the uv cache lock. Scan again before cleaning it."
        guard fd >= 0 else { return errno == ENOENT ? nil : unavailable }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK ? "uv is using this cache. Let the active uv task finish, then scan again." : unavailable
        }
        return nil
    }

    func clean() throws {
        try Task.checkCancellation()
        guard directory.path == directory.resolvingSymlinksInPath().path,
              !FolderExclusions(paths: exclusions).blocksCleanup(directory),
              let current = Self.identity(measured), current == (device, inode),
              try tool.cacheDirectory(executable: executable, home: home).path == directory.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if let lockReason {
            throw NSError(domain: "SpaceTargetCache", code: 1, userInfo: [NSLocalizedDescriptionKey: lockReason])
        }
        let result: PackageToolCommandResult
        if tool == .lume || tool == .pnpm {
            result = try tool.pruneReviewedStore(executable: executable, directory: directory, home: home)
        } else {
            let options = tool == .go ? [] : [tool == .npm ? "--cache" : "--cache-dir", directory.path]
            result = try PackageToolCommand.run(executable: executable, arguments: tool.arguments + options,
                directory: home, goBuildCache: tool == .go ? directory : nil)
        }
        guard result.status == 0 else {
            throw NSError(domain: "SpaceTargetCache", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey:
                "\(tool.title) exited with status \(result.status). Cleanup may be partial."])
        }
    }

    private static func identity(_ url: URL) -> (UInt64, UInt64)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }
}
