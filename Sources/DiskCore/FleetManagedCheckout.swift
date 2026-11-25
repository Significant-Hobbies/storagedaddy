import Darwin
import Foundation

/// Fleet's registry owns leases and deletion receipts for managed checkouts.
public enum FleetManagedCheckout {
    private struct Record: Decodable {
        let id: String
        let path: String
        let state: String
    }

    public struct Preview: Sendable {
        public let candidate: GitWorktreeCandidate
        public let head: String
        public let blockers: [String]
        public let eligible: Bool
        public var status: String {
            if eligible { return "Merged · ready to remove" }
            switch blockers.first {
            case "unknown-ignored-data": return "Kept · contains unrecognized ignored files"
            case "merge-not-verified": return "Kept · merge unverified"
            case "command-running", "open-files": return "Kept · in use"
            case "dirty-or-untracked": return "Kept · local changes"
            default: return "Kept · " + (blockers.first?.replacingOccurrences(of: "-", with: " ") ?? "owner verification incomplete")
            }
        }
    }

    private struct Response: Decodable {
        let id: String?
        let path: String?
        let state: String?
        let action: String
        let head: String?
        let blockers: [String]?
    }

    static func registry(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Fleet/Agent Workspaces.noindex")
    }

    public static func manages(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let root = registry(home: home)
        let parent = url.deletingLastPathComponent()
        return parent.deletingLastPathComponent().standardizedFileURL.path == root.path &&
            ["retired", "worktrees"].contains(parent.lastPathComponent)
    }

    private static func closed(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let root = registry(home: home)
        guard manages(url, home: home), url.deletingLastPathComponent().lastPathComponent == "retired" else { return false }
        let id = url.lastPathComponent
        let file = root.appendingPathComponent("manifests").appendingPathComponent(id + ".json")
        guard let meta = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              meta.isRegularFile == true, meta.isSymbolicLink == false, let size = meta.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return false }
        return record.id == id && record.path == url.path && record.state == "closed"
    }

    static func isReserved(_ url: URL) -> Bool { manages(url) && !closed(url) }

    private struct Lease: Decodable {
        let id: String?
        let repo: String?
    }

    private static func hasWorkspaceLease(_ checkout: URL, registry: URL) -> Bool {
        let directory = registry.appendingPathComponent("jobs")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return true }
        for file in entries where file.pathExtension == "json" {
            guard let meta = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  meta.isRegularFile == true, meta.isSymbolicLink == false, let size = meta.fileSize, size <= 65_536,
                  let data = try? Data(contentsOf: file), let lease = try? JSONDecoder().decode(Lease.self, from: data),
                  lease.repo != nil || lease.id != nil else { return true }
            if lease.id == checkout.lastPathComponent || lease.repo == checkout.path ||
                lease.repo?.hasPrefix(checkout.path + "/") == true { return true }
        }
        return false
    }

    static func containsReservedProject(_ url: URL) -> Bool {
        let root = registry(home: FileManager.default.homeDirectoryForCurrentUser)
        guard url.path.hasPrefix(root.path + "/") else { return false }
        var ancestor = url
        while ancestor.path != root.path && ancestor.path != "/" {
            if manages(ancestor) { return isReserved(ancestor) || hasWorkspaceLease(ancestor, registry: root) }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    private static func command(_ candidate: GitWorktreeCandidate, preview: Bool, home: URL) throws -> Response {
        let root = registry(home: home)
        let url = candidate.url
        let executable = home.appendingPathComponent(".local/bin/fleet-workspace")
        var metadata = stat()
        guard closed(url, home: home), url.resolvingSymlinksInPath().path == url.path, lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, UInt64(metadata.st_dev) == candidate.device,
              UInt64(metadata.st_ino) == candidate.inode, FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw GitWorktreeError.changed }
        let args = ["-p", "(version 1)(allow default)(deny network*)", "/usr/bin/env",
                    "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    executable.path, "close", "--id", url.lastPathComponent, "--root", root.path] + (preview ? ["--dry-run"] : [])
        let result = try PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: args, directory: root, timeout: preview ? 15 : 180, maximumOutputBytes: 1_048_576,
            requireCompleteOutput: true, mergeStandardError: false)
        guard result.status == 0 else { throw GitWorktreeError.command("Fleet exited with status \(result.status). Refresh the worktree review.") }
        return try JSONDecoder().decode(Response.self, from: Data(result.output.utf8))
    }

    public static func inspect(_ candidate: GitWorktreeCandidate, exclusions: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Preview {
        guard !FolderExclusions(paths: exclusions).blocksCleanup(candidate.url) else { throw GitWorktreeError.unsafe("excluded location") }
        let result = try command(candidate, preview: true, home: home)
        guard result.id == candidate.url.lastPathComponent, result.path == candidate.url.path, result.state == "closed"
        else { throw GitWorktreeError.changed }
        let blockers = result.blockers ?? []
        return Preview(candidate: candidate, head: result.head ?? "", blockers: blockers,
                       eligible: result.action == "delete-worktree" && blockers.isEmpty && result.head?.isEmpty == false)
    }

    public static func remove(_ reviewed: Preview, exclusions: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let fresh = try inspect(reviewed.candidate, exclusions: exclusions, home: home)
        guard reviewed.eligible, fresh.eligible, fresh.head == reviewed.head else { throw GitWorktreeError.changed }
        let response = try command(reviewed.candidate, preview: false, home: home)
        guard response.action == "delete-worktree", !FileManager.default.fileExists(atPath: reviewed.candidate.url.path)
        else { throw GitWorktreeError.command("Check the Fleet operation receipt and scan again.") }
    }
}
