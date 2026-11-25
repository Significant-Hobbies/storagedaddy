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

    static func discover(home: URL, exclusions: [String]) throws -> [Self] {
        var result: [Self] = []
        for tool in [PackageCacheTool.uv, .npm] {
            try Task.checkCancellation()
            let expected = (tool == .uv ? [".cache/uv", "Library/Caches/uv"] : [".npm"])
                .map { home.appendingPathComponent($0).standardizedFileURL }
            guard expected.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let executable = tool.executable(home: home),
                  let directory = try? tool.cacheDirectory(executable: executable, home: home),
                  expected.contains(where: { $0.path == directory.path }),
                  directory.path == directory.resolvingSymlinksInPath().path,
                  !FolderExclusions(paths: exclusions).blocksCleanup(directory) else { continue }
            let measured = tool == .npm ? directory.appendingPathComponent("_cacache") : directory
            guard let identity = identity(measured),
                  let report = try? PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/du"),
                      arguments: ["-skx", measured.path], directory: home, timeout: 120),
                  report.status == 0, let first = report.output.split(whereSeparator: { $0.isWhitespace }).first,
                  let kib = Int64(first), kib > 0, kib <= Int64.max / 1024 else { continue }
            result.append(Self(tool: tool, executable: executable, home: home, directory: directory,
                               measured: measured, device: identity.0, inode: identity.1, bytes: kib * 1024,
                               exclusions: exclusions))
        }
        return result
    }

    /// Probe uv's existing advisory lock without creating or changing the lock file.
    /// The manager still owns locking when it runs after this point-in-time check.
    var lockReason: String? {
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
        let option = tool == .uv ? "--cache-dir" : "--cache"
        let result = try PackageToolCommand.run(executable: executable, arguments: tool.arguments + [option, directory.path],
                                                directory: home)
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
