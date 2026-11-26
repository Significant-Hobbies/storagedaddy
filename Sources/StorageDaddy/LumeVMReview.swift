import Darwin
import DiskCore
import Foundation

/// Whole VMs contain guest data. These candidates belong only in the separate,
/// explicit VM removal review and are never automatic cache selections.
struct LumeVMReview: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bytes: Int64
    let device: UInt64
    let inode: UInt64
    private let home: URL
    private let executable: URL
    private let contents: [String: FileIdentity]

    private struct Record: Decodable {
        let name: String
        let status: String
        let locationName: String
        let savedState: Bool?
        let provisioningOperation: String?
        let diskSize: DiskSize
        struct DiskSize: Decodable { let total: UInt64 }
    }

    private struct FileIdentity: Equatable, Sendable {
        let inode: ino_t
        let bytes: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ metadata: stat) {
            inode = metadata.st_ino
            bytes = metadata.st_size
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        }
    }

    static func discover(home: URL, exclusions: [String]) throws -> [Self] {
        let storage = home.appendingPathComponent(".lume").standardizedFileURL
        guard let executable = PackageCacheTool.lume.executable(home: home),
              storage.path == storage.resolvingSymlinksInPath().path,
              !FolderExclusions(paths: exclusions).contains(storage.path),
              metadata(storage, type: S_IFDIR) != nil else { return [] }
        let profile = #"(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (literal "/dev/null"))"#
        let list = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile, executable.path, "ls", "--storage", "home", "--format", "json"],
            directory: home, timeout: 20, requireCompleteOutput: true, mergeStandardError: false)
        guard list.status == 0 else { throw CocoaError(.fileReadUnknown) }
        let records = try JSONDecoder().decode([Record].self, from: Data(list.output.utf8))
        let blocked = FolderExclusions(paths: exclusions)
        var reviews: [Self] = []
        for record in records {
            try Task.checkCancellation()
            guard record.status == "stopped", record.locationName == "home", record.savedState != true,
                  record.provisioningOperation == nil, record.name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,126}$"#,
                      options: .regularExpression) != nil else { continue }
            let url = storage.appendingPathComponent(record.name)
            guard !blocked.blocksCleanup(url), !blocked.blocksCleanup(guardURL(for: url)),
                  let dir = metadata(url, type: S_IFDIR), let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            else { continue }
            let names = Set(entries)
            let required: Set<String> = ["config.json", "disk.img", "nvram.bin"]
            let allowed = required.union([".manifest-digest", "sessions.json", ".run-owner.json", ".DS_Store"])
            guard required.isSubset(of: names), names.isSubset(of: allowed) else { continue }
            var files: [String: FileIdentity] = [:]
            var allocated: Int64 = 0
            for entry in entries {
                guard let info = metadata(url.appendingPathComponent(entry), type: S_IFREG),
                      info.st_nlink == 1, info.st_dev == dir.st_dev else { break }
                files[entry] = FileIdentity(info)
                allocated += Int64(info.st_blocks) * 512
            }
            guard files.count == names.count, files["disk.img"]?.bytes == Int64(exactly: record.diskSize.total) else { continue }
            reviews.append(Self(url: url, name: record.name, bytes: allocated, device: UInt64(UInt32(bitPattern: dir.st_dev)),
                                inode: dir.st_ino, home: home, executable: executable, contents: files))
        }
        return reviews.sorted { $0.bytes > $1.bytes }
    }

    func remove(exclusions: [String]) throws {
        guard let fresh = try Self.discover(home: home, exclusions: exclusions).first(where: { $0.url.path == url.path }),
              fresh.device == device, fresh.inode == inode, fresh.contents == contents, fresh.executable == executable
        else { throw CocoaError(.fileWriteNoPermission) }
        try CleanupActiveUse.validateCacheIsIdle(url)
        let guardFile = Self.guardURL(for: url)
        // Lume takes an exclusive lock on this file while deleting. Precreate the
        // empty file so its Foundation implementation needs no parent write access.
        let fd = open(guardFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_uid == getuid(), file.st_mode & S_IFMT == S_IFREG,
              file.st_nlink == 1, file.st_size == 0,
              let vmPath = realpath(url.path, nil) else { throw CocoaError(.fileWriteNoPermission) }
        defer { free(vmPath) }
        guard let guardPath = realpath(guardFile.path, nil) else { throw CocoaError(.fileWriteNoPermission) }
        defer { free(guardPath) }
        try Task.checkCancellation()
        let profile = #"(version 1)(allow default)(deny network*)(deny signal)(deny file-write*)(allow file-write* (subpath (param "VM")) (literal (param "GUARD")) (literal "/dev/null"))"#
        let result = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-D", "VM=" + String(cString: vmPath), "-D", "GUARD=" + String(cString: guardPath),
                        "-p", profile, executable.path, "delete", name, "--storage", "home", "--force"], directory: home)
        var remaining = stat()
        guard result.status == 0, lstat(url.path, &remaining) != 0, errno == ENOENT else {
            throw NSError(domain: "LumeRemoval", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey:
                "Lume could not confirm removal of this VM. Refresh its status before trying again."])
        }
    }

    private static func guardURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".resize.guard")
    }

    private static func metadata(_ url: URL, type: mode_t) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == type else { return nil }
        return info
    }
}
