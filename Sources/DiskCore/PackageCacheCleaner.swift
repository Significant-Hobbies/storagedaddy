import Darwin
import Foundation

/// Uses each manager's own cleanup rules. In particular Homebrew cleanup can
/// remove old installed versions, so a directory named Homebrew is not parity.
public enum PackageCacheTool: String, CaseIterable, Identifiable, Sendable {
    case yarn, uv, npm, brew, pip, pnpm
    public var id: String { rawValue }
    public var title: String { self == .brew ? "Homebrew" : self == .pip ? "pip3" : rawValue }
    public var arguments: [String] {
        switch self {
        case .yarn, .uv: ["cache", "clean"]
        case .npm: ["cache", "clean", "--force"]
        case .brew: ["cleanup", "-s"]
        case .pip: ["cache", "purge"]
        case .pnpm: ["store", "prune"]
        }
    }
    public var command: String { ([title == "Homebrew" ? "brew" : title] + arguments).joined(separator: " ") }
    public var consequence: String {
        switch self {
        case .brew: "Permanently removes cached downloads, old installed versions, stale logs and temporary files. Homebrew may also remove unused installed dependencies. Rollback versions and offline installers may be lost."
        case .uv: "Permanently clears uv’s cache using uv’s locking and link rules. Future installs may download or rebuild packages."
        case .pnpm: "Permanently prunes unreferenced packages from pnpm’s store. Installed project dependencies remain; future installs may download packages again."
        default: "Permanently clears downloaded packages and cache records. Future installs may need the network; unavailable versions cannot be recovered from Trash."
        }
    }

    public func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let name = self == .pip ? "pip3" : rawValue
        let pnpmRoots = self == .pnpm ? [
                     home.appendingPathComponent(".local/share/mise/shims").path,
                     home.appendingPathComponent(".local/share/mise/installs/node/lts/bin").path,
                     home.appendingPathComponent("Library/pnpm").path] : []
        let roots = [home.appendingPathComponent(".local/bin").path] + pnpmRoots
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
        case .pnpm: args = ["store", "path"]
        }
        let result = try PackageToolCommand.run(executable: executable, arguments: args, directory: home, timeout: 20)
        guard result.status == 0,
              let line = result.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { $0.hasPrefix("/") }),
              line != "/", !line.contains("\0") else {
            throw NSError(domain: "CacheCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: "The tool did not report an absolute cache directory. Yarn Berry project caches can be inspected through Scan Folder."])
        }
        return URL(fileURLWithPath: line).standardizedFileURL
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
                           maximumOutputBytes: Int = 262_144, requireCompleteOutput: Bool = false, mergeStandardError: Bool = true) throws -> PackageToolCommandResult {
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
        process.environment = environment
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
