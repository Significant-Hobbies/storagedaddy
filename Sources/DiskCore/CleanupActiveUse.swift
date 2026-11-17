import Darwin
import Foundation

/// Positive evidence of current use, including working directories and mapped
/// files. Absence of an open handle is not proof that a folder is never needed.
enum CleanupActiveUse {
    struct OpenFiles: Sendable {
        fileprivate let coveredRoots: Set<String>
        fileprivate let users: [String: String]
        private let capturedAt: ContinuousClock.Instant

        fileprivate init(paths: [String], output: String, capturedAt: ContinuousClock.Instant) {
            coveredRoots = Set(paths.map(CleanupGuidance.normalized))
            users = CleanupActiveUse.users(of: coveredRoots, in: output)
            self.capturedAt = capturedAt
        }

        var isFresh: Bool { capturedAt.duration(to: .now) < .seconds(1) }

        func user(of path: String) -> String? { users[CleanupGuidance.normalized(path)] }
    }

    static func captureOpenFiles(for paths: [String]) throws -> OpenFiles {
        let started = ContinuousClock.now
        let output = try probe(executable: "/usr/sbin/lsof",
            arguments: ["-w", "-n", "-P", "-F0pcn", "-u", String(getuid())], maximumOutputBytes: 32 * 1024 * 1024)
        return OpenFiles(paths: paths, output: output, capturedAt: started)
    }

    static func validate(urls: [URL], home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                         openFiles: OpenFiles? = nil) throws {
        let paths = urls.map { CleanupGuidance.normalized($0.path) }
        let evidence: OpenFiles
        if let openFiles, openFiles.isFresh, paths.allSatisfy(openFiles.coveredRoots.contains) {
            evidence = openFiles
        } else {
            evidence = try captureOpenFiles(for: paths)
        }
        for url in urls {
            if let user = evidence.user(of: url.path) {
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
                maximumOutputBytes: maximumOutputBytes, requireCompleteOutput: true, mergeStandardError: false,
                locale: "en_US.UTF-8")
            guard result.status == 0 else { throw error("Process evidence unavailable.") }
            return result.output
        } catch is CancellationError { throw CancellationError() }
        catch { throw self.error("The current-use check could not finish completely. Nothing was approved for cleanup; keep these items and try again.") }
    }

    static func user(of path: String, in output: String) -> String? {
        let root = CleanupGuidance.normalized(path)
        return users(of: [root], in: output)[root]
    }

    private static func users(of roots: Set<String>, in output: String) -> [String: String] {
        var matches: [String: String] = [:]
        let onlyRoot = roots.count == 1 ? roots.first : nil
        var pid = "", command = "a running process"
        for record in output.split(separator: "\0") {
            let field = record.drop(while: \.isNewline)
            guard let type = field.first else { continue }
            let value = field.dropFirst()
            switch type {
            case "p": pid = String(value); command = "a running process"
            case "c": command = String(value)
            case "n":
                guard value.hasPrefix("/") else { continue }
                let file = CleanupGuidance.normalized(String(value))
                if let onlyRoot {
                    if file == onlyRoot || file.hasPrefix(onlyRoot + "/") { return [onlyRoot: "\(command) (PID \(pid))"] }
                    continue
                }
                var ancestor = file[...]
                repeat {
                    let path = String(ancestor)
                    if roots.contains(path), matches[path] == nil { matches[path] = "\(command) (PID \(pid))" }
                    guard let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex else { break }
                    ancestor = ancestor[..<slash]
                } while !ancestor.isEmpty
            default: break
            }
            if matches.count == roots.count { break }
        }
        return matches
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CleanupActiveUse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
