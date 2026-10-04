import Foundation
import Darwin

/// Local repository metadata for review. No fetch, checkout, file-content reads,
/// or cleanup decision is made by this probe. Failed checks stay unknown.
public struct GitCheckoutEvidence: Sendable {
    public let changedEntries: Int?
    public let unpushedCommits: Int?
    public let stashes: Int?
    public init(changedEntries: Int?, unpushedCommits: Int?, stashes: Int?) {
        self.changedEntries = changedEntries; self.unpushedCommits = unpushedCommits; self.stashes = stashes
    }
}

public enum GitCheckoutProbe {
    public static func collect(at url: URL, run: (URL, [String]) -> String? = runLocal) -> GitCheckoutEvidence {
        let status = run(url, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        let ahead = run(url, ["rev-list", "--count", "@{upstream}..HEAD"])
        let stash = run(url, ["stash", "list", "--format=%gd"])
        return GitCheckoutEvidence(changedEntries: status.map(countChangedEntries),
            unpushedCommits: ahead.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            stashes: stash.map { $0.split(separator: "\n").count })
    }

    /// In porcelain -z a rename/copy has a second path field, not a second change.
    static func countChangedEntries(_ text: String) -> Int {
        let records = text.split(separator: "\0", omittingEmptySubsequences: true)
        var count = 0, i = 0
        while i < records.count {
            let flags = records[i].prefix(2)
            count += 1; i += (flags.contains("R") || flags.contains("C")) ? 2 : 1
        }
        return count
    }

    public static func runLocal(at url: URL, arguments: [String]) -> String? {
        GitReadTask(url: url, arguments: arguments).run()
    }
}

/// Bounded output and time, including stderr; a broken repository cannot hang UI.
private final class GitReadTask: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var output = Data()
    private var overflow = false
    private let group = DispatchGroup()
    init(url: URL, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null", "-C", url.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_LITERAL_PATHSPECS": "1"]
        process.standardInput = FileHandle.nullDevice
    }
    func run() -> String? {
        let out = Pipe()
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { return }
                lock.lock()
                let remaining = 65_536 - output.count
                if chunk.count > remaining { overflow = true }
                output.append(chunk.prefix(max(0, remaining)))
                lock.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard group.wait(timeout: .now() + 0.25) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !timedOut, !overflow, process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
