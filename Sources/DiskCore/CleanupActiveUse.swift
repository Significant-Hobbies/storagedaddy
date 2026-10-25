import Darwin
import Foundation

/// Positive evidence of current use, including working directories and mapped
/// files. Absence of an open handle is not proof that a folder is never needed.
enum CleanupActiveUse {
    static func validate(urls: [URL], home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        let text = try probe(executable: "/usr/sbin/lsof",
            arguments: ["-w", "-n", "-P", "-F0pcn", "-u", String(getuid())], maximumOutputBytes: 32 * 1024 * 1024)
        for url in urls {
            if let user = user(of: url.path, in: text) {
                throw error("\(url.lastPathComponent) is in use by \(user). Quit that process before cleanup.")
            }
        }
        let entries = try NpxCacheReview.affectedEntries(urls: urls, home: home)
        if urls.contains(where: { ToolStorage.containingData(path: $0.path) != nil }) {
            let owners = try probe(executable: "/bin/ps", arguments: ["-ww", "-U", String(getuid()), "-o", "pid=,comm="],
                                   maximumOutputBytes: 4 * 1024 * 1024)
            try ToolStorage.validateActiveUse(urls: urls, processOutput: owners)
        }
        if !entries.isEmpty {
            // Only interpreted locally for process/path and CLI-name matches.
            // Arguments are never logged, persisted or displayed.
            let processes = try probe(executable: "/bin/ps", arguments: ["-ww", "-U", String(getuid()), "-o", "pid=,command="],
                                      maximumOutputBytes: 8 * 1024 * 1024)
            try NpxCacheReview.validate(entries: entries, processOutput: processes)
        }
    }

    private static func probe(executable: String, arguments: [String], maximumOutputBytes: Int) throws -> String {
        do {
            let result = try PackageToolCommand.run(executable: URL(fileURLWithPath: executable), arguments: arguments,
                directory: FileManager.default.temporaryDirectory, timeout: 15,
                maximumOutputBytes: maximumOutputBytes, requireCompleteOutput: true, mergeStandardError: false)
            guard result.status == 0 else { throw error("Process evidence unavailable.") }
            return result.output
        } catch is CancellationError { throw CancellationError() }
        catch { throw self.error("The current-use check could not finish completely. Nothing was approved for cleanup; keep these items and try again.") }
    }

    static func user(of path: String, in output: String) -> String? {
        let root = CleanupGuidance.normalized(path)
        var pid = "", command = "a running process"
        for field in output.split(separator: "\0") {
            let field = field.trimmingCharacters(in: .newlines)
            guard let type = field.first else { continue }
            let value = String(field.dropFirst())
            switch type {
            case "p": pid = value; command = "a running process"
            case "c": command = value
            case "n":
                guard value.hasPrefix("/") else { continue }
                let file = CleanupGuidance.normalized(value)
                if file == root || file.hasPrefix(root + "/") { return "\(command) (PID \(pid))" }
            default: break
            }
        }
        return nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CleanupActiveUse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
