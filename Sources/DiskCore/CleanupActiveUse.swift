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

        var isFresh: Bool { capturedAt.duration(to: .now) < .seconds(2) }

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
        let paths = urls.flatMap { [$0.path, metroProject(for: $0)?.path].compactMap { $0 } }.map(CleanupGuidance.normalized)
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
            if let project = metroProject(for: url), let user = evidence.user(of: project.path) {
                throw error("The Metro project is in use by \(user). Quit that process before cleanup.")
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
            let processes = try npxProcessSnapshot()
            try NpxCacheReview.validate(entries: entries, processOutput: processes)
        }
    }

    static func npxProcessSnapshot() throws -> String {
        try probe(executable: "/bin/ps", arguments: ["-ww", "-U", String(getuid()), "-o", "pid=,command="],
                                      maximumOutputBytes: 8 * 1024 * 1024)
    }

    static func metroProject(for cache: URL) -> URL? {
        cache.lastPathComponent == ".metro-cache" ? cache.deletingLastPathComponent() : nil
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
        let onlyKey = onlyRoot.map(processPathKey)
        let rootsByKey = Dictionary(grouping: roots, by: processPathKey)
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
                let file = processPathKey(CleanupGuidance.normalized(decodePath(value)))
                if let onlyRoot, let onlyKey {
                    if file == onlyKey || file.hasPrefix(onlyKey + "/") { return [onlyRoot: "\(command) (PID \(pid))"] }
                    continue
                }
                var ancestor = file[...]
                repeat {
                    for path in rootsByKey[String(ancestor)] ?? [] where matches[path] == nil {
                        matches[path] = "\(command) (PID \(pid))"
                    }
                    guard let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex else { break }
                    ancestor = ancestor[..<slash]
                } while !ancestor.isEmpty
            default: break
            }
            if matches.count == roots.count { break }
        }
        return matches
    }

    private static func decodePath(_ path: Substring) -> String {
        guard path.contains("\\") else { return String(path) }
        let bytes = Array(path.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard byte == 92, index < bytes.count else { result.append(byte); continue }
            switch bytes[index] {
            case 92: result.append(92)
            case 98: result.append(8)
            case 102: result.append(12)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 118: result.append(11)
            case 120 where index + 2 < bytes.count:
                if let high = hexDigit(bytes[index + 1]), let low = hexDigit(bytes[index + 2]) {
                    result.append(high * 16 + low)
                    index += 3
                    continue
                }
                result.append(byte)
                continue
            default: result.append(byte); continue
            }
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func processPathKey(_ path: String) -> String {
        // lsof prints some controls as caret pairs and leaves literal carets unchanged.
        // Treat both spellings as active when they cannot be distinguished.
        guard path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return path }
        let bytes = path.utf8.flatMap { byte -> [UInt8] in
            if byte < 32 { return [94, byte + 64] }
            if byte == 127 { return [94, 63] }
            return [byte]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CleanupActiveUse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
