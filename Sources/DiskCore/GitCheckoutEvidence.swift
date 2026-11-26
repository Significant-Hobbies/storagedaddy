import Foundation

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
        // Drain the pipe on this thread. A separate reader can be delayed on
        // a busy machine even when Git has already completed successfully.
        let result = try? PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                        "-c", "core.hooksPath=/dev/null", "-C", url.path] + arguments,
            directory: url, timeout: 5, maximumOutputBytes: 65_536,
            requireCompleteOutput: true, mergeStandardError: false,
            environmentOverride: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0",
                                  "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
                                  "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_LITERAL_PATHSPECS": "1"])
        guard let result, result.status == 0 else { return nil }
        return result.output
    }
}
