import Darwin
import Foundation

/// Uses each manager's own cleanup rules. In particular Homebrew cleanup can
/// remove old installed versions, so a directory named Homebrew is not parity.
public enum PackageCacheTool: String, CaseIterable, Identifiable, Sendable {
    case yarn, uv, npm, brew, pip, pnpm, go, lume
    public var id: String { rawValue }
    public var title: String { self == .brew ? "Homebrew" : self == .pip ? "pip3" : rawValue }
    public var arguments: [String] {
        switch self {
        case .yarn, .uv: ["cache", "clean"]
        case .npm: ["cache", "clean", "--force"]
        case .brew: ["cleanup", "-s"]
        case .pip: ["cache", "purge"]
        case .pnpm: ["store", "prune"]
        case .go: ["clean", "-cache"]
        case .lume: ["prune"]
        }
    }
    public var command: String { ([title == "Homebrew" ? "brew" : title] + arguments).joined(separator: " ") }
    public var consequence: String {
        switch self {
        case .lume: "Removes downloaded VM images from the Lume cache. Existing virtual machines stay installed. Pulling an image again requires a download."
        case .go: "Clears compiled Go build artifacts. The next build recompiles them."
        case .brew: "Permanently removes cached downloads, old installed versions, stale logs and temporary files. Homebrew may also remove unused installed dependencies. Rollback versions and offline installers may be lost."
        case .uv: "Permanently clears uv’s cache using uv’s locking and link rules. Future installs may download or rebuild packages."
        case .pnpm: "Pruning can empty the download store. Installed projects keep their packages. Future installs may download them again, and shared files can reduce the space recovered."
        default: "Permanently clears downloaded packages and cache records. Future installs may need the network; unavailable versions cannot be recovered from Trash."
        }
    }

    public func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let name = self == .pip ? "pip3" : rawValue
        let pnpmRoots = self == .pnpm ? ["/opt/homebrew/bin", "/usr/local/bin",
                     home.appendingPathComponent(".local/share/mise/shims").path,
                     home.appendingPathComponent(".local/share/mise/installs/node/lts/bin").path,
                     home.appendingPathComponent("Library/pnpm").path] : []
        let roots = [home.appendingPathComponent(".local/bin").path] + pnpmRoots
            + (self == .go ? ["/usr/local/go/bin", home.appendingPathComponent(".local/share/mise/shims").path] : [])
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return roots.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func cacheDirectory(executable: URL, home: URL) throws -> URL {
        let args: [String]
        switch self {
        case .yarn: args = ["cache", "dir"]
        case .uv, .pip: args = ["cache", "dir"]
        case .npm: args = ["config", "get", "cache"]
        case .brew: args = ["--cache"]
        case .go: args = ["env", "GOCACHE"]
        case .pnpm: args = ["store", "path"]
        case .lume: args = ["config", "get"]
        }
        let result: PackageToolCommandResult
        if self == .lume || self == .pnpm {
            let profile = #"(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (literal "/dev/null"))"#
            result = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", profile, executable.path] + args, directory: home, timeout: 20,
                requireCompleteOutput: true, mergeStandardError: false, nodeToolPath: self == .pnpm)
        } else {
            result = try PackageToolCommand.run(executable: executable, arguments: args, directory: home, timeout: 20)
        }
        if self == .lume {
            let lines = result.output.components(separatedBy: .newlines)
            let cache = home.appendingPathComponent(".lume/cache").standardizedFileURL
            let location = lines.filter { $0.hasPrefix("Cache directory: ") }
            // The native prune command targets every cached image. Only the default
            // image cache is supported, and registered VM storage must stay outside it.
            guard result.status == 0, location.count == 1,
                  ["Cache directory: ~/.lume/cache", "Cache directory: " + cache.path].contains(location[0]),
                  let heading = lines.firstIndex(of: "Configured VM storage locations:") else {
                throw CocoaError(.fileReadUnknown)
            }
            let stores = lines.dropFirst(heading + 1).filter { !$0.isEmpty }
            guard !stores.isEmpty else { throw CocoaError(.fileReadUnknown) }
            for store in stores {
                guard store.hasPrefix("  - "), let colon = store.range(of: ": ") else { throw CocoaError(.fileReadUnknown) }
                var path = String(store[colon.upperBound...])
                if path.hasSuffix(" (default)") { path.removeLast(" (default)".count) }
                if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
                guard path.hasPrefix("/"), !FolderExclusions(paths: [cache.path]).contains(
                    URL(fileURLWithPath: path).resolvingSymlinksInPath().path) else { throw CocoaError(.fileReadUnknown) }
            }
            return cache
        }
        guard result.status == 0,
              let line = result.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { $0.hasPrefix("/") }),
              line != "/", !line.contains("\0") else {
            throw NSError(domain: "CacheCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: "The tool did not report an absolute cache directory. Yarn Berry project caches can be inspected through Scan Folder."])
        }
        return URL(fileURLWithPath: line).standardizedFileURL
    }
    /// Scope native prune to the reviewed directory. pnpm normally also purges its
    /// separate metadata cache, so give it a private scratch cache for this command.
    public func pruneReviewedStore(executable: URL, directory: URL, home: URL) throws -> PackageToolCommandResult {
        guard self == .lume || self == .pnpm, directory.path == directory.resolvingSymlinksInPath().path,
              try cacheDirectory(executable: executable, home: home).path == directory.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try CleanupActiveUse.validateCacheIsIdle(directory)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("StorageDaddy-prune-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let profile = #"(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath (param "STORE")) (subpath (param "SCRATCH")) (literal "/dev/null"))"#
        let options = self == .pnpm ? ["--store-dir", directory.path, "--config.cache-dir=" + scratch.path] : []
        if self == .lume {
            let children = try fm.contentsOfDirectory(atPath: directory.path)
            guard children.contains("ghcr"), Set(children).isSubset(of: ["ghcr", ".DS_Store"]),
                  directory.appendingPathComponent("ghcr").resolvingSymlinksInPath().path == directory.appendingPathComponent("ghcr").path else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        guard let storePath = realpath(directory.path, nil), let scratchPath = realpath(scratch.path, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(storePath); free(scratchPath) }
        return try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-D", "STORE=" + String(cString: storePath), "-D", "SCRATCH=" + String(cString: scratchPath), "-p", profile,
                        executable.path] + options + arguments, directory: home, nodeToolPath: self == .pnpm)
    }

}

public struct PackageToolCommandResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum PackageToolCommand {
    /// Fixed executable and arguments, never a shell command. Drain output even
    /// after the display bound; a verbose manager cannot deadlock the pipe.
    public static func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval = 300,
                           maximumOutputBytes: Int = 262_144, requireCompleteOutput: Bool = false, mergeStandardError: Bool = true,
                           locale: String? = nil, goBuildCache: URL? = nil, nodeToolPath: Bool = false,
                           environmentOverride: [String: String]? = nil) throws -> PackageToolCommandResult {
        try Task.checkCancellation()
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        if mergeStandardError { process.standardError = pipe }
        else { process.standardError = FileHandle.nullDevice }
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["COREPACK_ENABLE_NETWORK"] = "0"
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        if nodeToolPath {
            // Finder starts GUI apps with a minimal PATH. pnpm's executable can
            // be a Node shebang even when located through its absolute path.
            environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        }
        if let goBuildCache { environment["GOCACHE"] = goBuildCache.path }
        if let locale { environment["LC_ALL"] = locale }
        process.environment = environmentOverride ?? environment
        try process.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        var stoppedAt: Date?, cancelled = false, truncated = false
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let retained = min(count, max(0, maximumOutputBytes - data.count))
                if retained < count { truncated = true }
                data.append(contentsOf: buffer.prefix(retained))
            } else if !process.isRunning { break }
            if Task.isCancelled || Date() > deadline {
                cancelled = true
                if stoppedAt == nil { process.terminate(); stoppedAt = Date() }
                else if Date().timeIntervalSince(stoppedAt!) > 1 { _ = kill(process.processIdentifier, SIGKILL) }
            }
            if count <= 0 { usleep(10_000) }
        }
        process.waitUntilExit()
        try pipe.fileHandleForReading.close()
        if cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw NSError(domain: "CacheCleaner", code: 2, userInfo: [NSLocalizedDescriptionKey: "The tool exceeded its time limit. Its cleanup may be partial; inspect or measure the cache again."])
        }
        if requireCompleteOutput && (truncated || String(data: data, encoding: .utf8) == nil) {
            throw NSError(domain: "CacheCleaner", code: 6, userInfo: [NSLocalizedDescriptionKey: "Current-use evidence was incomplete. Nothing was approved for cleanup."])
        }
        return PackageToolCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
