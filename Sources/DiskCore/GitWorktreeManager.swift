import CryptoKit
import Darwin
import Foundation

public struct GitWorktreeCandidate: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let allocatedBytes: Int64
    let device: UInt64
    let inode: UInt64
}

public struct GitWorktreeReview: Identifiable, Sendable {
    public var id: String { candidate.id }
    public let candidate: GitWorktreeCandidate
    public let commonDirectory: URL
    public let gitDirectory: URL
    public let isMainWorktree: Bool
    public let branch: String?
    public let head: String
    public let changedEntries: Int?
    public let aheadOfUpstream: Int?
    public let upstream: String?
    public let commitsOnlyHere: Int?
    public let lockReason: String?
    public let prunableReason: String?
    public let removalBlockers: [String]
    public var canRemove: Bool { removalBlockers.isEmpty }
    let evidence: GitWorktreeEvidence
    let tree: Data?
}

struct GitWorktreeEvidence: Equatable, Sendable {
    let root: WorktreeIdentity
    let pointer: WorktreeIdentity
    let common: WorktreeIdentity
    let admin: WorktreeIdentity
    let listing: WorktreeListing
    let status: String?
    let upstream: String?
    let ahead: Int?
    let unique: Int?
}

struct WorktreeIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ value: stat) {
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino); mode = value.st_mode; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

struct WorktreeListing: Equatable, Sendable {
    let path: String
    let head: String?
    let branch: String?
    let detached: Bool
    let bare: Bool
    let locked: String?
    let prunable: String?
    let main: Bool
}

public enum GitWorktreeError: Error, LocalizedError, Sendable {
    case unsafe(String), unknown(String), changed, command(String)
    public var errorDescription: String? {
        switch self {
        case .unsafe(let why): "Worktree kept: " + why
        case .unknown(let why): "Worktree could not be fully checked: " + why
        case .changed: "The worktree, Git metadata or review evidence changed. Review again; nothing was forced or overwritten."
        case .command(let why): "Git could not remove the worktree: " + why
        }
    }
}

/// Only explicit scanned checkouts are candidates. Git's sibling registration
/// list is read to identify this checkout; unseen siblings are never offered.
/// Branch refs remain in the repository. Removal permanently deletes files and
/// registration through non-force Git, so the app must explicitly review it.
public actor GitWorktreeManager {
    private var removing = false
    private let activeUse: @Sendable ([URL]) throws -> Void
    public init(activeUse: (@Sendable ([URL]) throws -> Void)? = nil) {
        self.activeUse = activeUse ?? { try CleanupActiveUse.validate(urls: $0) }
    }

    public static func discover(in scan: ScanResult) throws -> [GitWorktreeCandidate] {
        var roots = Set<Int>(), result: [GitWorktreeCandidate] = []
        for node in scan.nodes where node.name == ".git" {
            try Task.checkCancellation()
            guard !node.isSymlink, let parent = node.parent, scan.nodes.indices.contains(parent),
                  scan.nodes[parent].isDirectory, !scan.nodes[parent].isSymlink, roots.insert(parent).inserted else { continue }
            let root = scan.nodes[parent]
            result.append(GitWorktreeCandidate(url: scan.url(for: parent), allocatedBytes: root.allocatedBytes,
                device: root.device, inode: root.inode))
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    public func inspect(candidate: GitWorktreeCandidate, excludedFolders: [String] = []) async throws -> GitWorktreeReview {
        try Task.checkCancellation()
        let url = try Self.canonical(candidate.url)
        guard Self.readGit(at: url, arguments: ["--version"]) != nil else { throw GitWorktreeError.unknown("installed Git lacks the required local-only (--no-lazy-fetch) inspection support") }
        guard !FolderExclusions(paths: excludedFolders).blocksCleanup(url) else { throw GitWorktreeError.unsafe("an excluded folder is inside this worktree") }
        let root = try Self.identity(url)
        guard root.mode & UInt16(S_IFMT) == UInt16(S_IFDIR), root.device == candidate.device,
              root.inode == candidate.inode, candidate.device != 0, candidate.inode != 0 else { throw GitWorktreeError.changed }
        let pointerURL = url.appendingPathComponent(".git")
        let pointer = try Self.identity(pointerURL)
        guard pointer.mode & UInt16(S_IFMT) == UInt16(S_IFREG) || pointer.mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else { throw GitWorktreeError.unsafe(".git is not a regular file or directory") }
        let common = try Self.gitPath(at: url, option: "--git-common-dir")
        let admin = try Self.gitPath(at: url, option: "--git-dir")
        guard let top = Self.readGit(at: url, arguments: ["rev-parse", "--path-format=absolute", "--show-toplevel"]),
              try Self.canonical(Self.pathOutput(top)) == url else { throw GitWorktreeError.unknown("Git does not identify this exact checkout root") }
        guard let rawList = Self.readGit(at: url, arguments: ["worktree", "list", "--porcelain", "-z"]) else { throw GitWorktreeError.unknown("Git could not list this repository's worktrees") }
        let matches = try Self.parseList(rawList).filter { Self.systemAliases($0.path) == url.path }
        guard matches.count == 1, let listing = matches.first else { throw GitWorktreeError.unknown("this exact checkout is not uniquely registered with Git") }
        let isMain = listing.main || admin == common
        if !isMain {
            guard admin.deletingLastPathComponent() == common.appendingPathComponent("worktrees"),
                  pointer.mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { throw GitWorktreeError.unsafe(".git does not point to this repository's linked-worktree administration directory") }
        }
        guard let head = listing.head, Self.validObjectID(head),
              Self.readGit(at: url, arguments: ["rev-parse", "--verify", "HEAD"]).map(Self.trimLine) == head else { throw GitWorktreeError.unknown("HEAD is missing or changed") }
        if let branch = listing.branch {
            guard Self.readGit(at: url, arguments: ["symbolic-ref", "--quiet", "HEAD"]).map(Self.trimLine) == branch else { throw GitWorktreeError.changed }
        } else if !listing.detached { throw GitWorktreeError.unknown("HEAD is neither an attached branch nor a verified detached commit") }
        let status = Self.readGit(at: url, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])
        let changes = status.flatMap { Self.validStatus($0) ? GitCheckoutProbe.countChangedEntries($0) : nil }
        let unique = Self.count(Self.readGit(at: url, arguments: ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags"]))
        let upstream = listing.branch == nil ? nil : Self.readGit(at: url, arguments: ["rev-parse", "--symbolic-full-name", "@{upstream}"]).map(Self.trimLine)
        let ahead = upstream == nil ? nil : Self.count(Self.readGit(at: url, arguments: ["rev-list", "--count", "@{upstream}..HEAD"]))
        var blockers: [String] = []
        if isMain { blockers.append("The main checkout cannot be removed as a linked worktree.") }
        if let lock = listing.locked { blockers.append("Locked worktree" + (lock.isEmpty ? "." : ": " + lock)) }
        if let reason = listing.prunable { blockers.append("Git marks this registration prunable; inspect or repair it manually: " + reason) }
        if changes == nil { blockers.append("Working-tree status is unavailable, incomplete or too large.") }
        else if changes != 0 { blockers.append("Modified, staged or untracked files remain.") }
        if unique == nil { blockers.append("Commit reachability is unknown.") }
        else if unique != 0 { blockers.append("HEAD contains commits reachable from no branch, remote or tag.") }
        if listing.branch != nil {
            if upstream == nil || ahead == nil { blockers.append("No verified upstream or ahead count; unpushed-commit safety is unknown.") }
            else if ahead != 0 { blockers.append("This branch has commits ahead of its upstream.") }
        }
        var tree: Data?
        if blockers.isEmpty {
            let fresh = try await DiskScanner.scan(root: url, excludedFolders: excludedFolders)
            guard let freshRoot = fresh.nodes.first else { throw GitWorktreeError.unknown("the current directory could not be scanned") }
            try CleanupSafety.validate(url: url, expected: freshRoot, root: url.deletingLastPathComponent())
            if fresh.skipped != 0 || !fresh.errors.isEmpty || freshRoot.isScanIncomplete == true {
                blockers.append("The worktree contains sensitive, excluded or unreadable paths; it cannot be safely removed.")
            } else {
                // No content reads: preserve the exact reviewed path/identity/size/date
                // inventory, including ignored files that Git status does not report.
                tree = try Self.treeFingerprint(fresh)
                do { try activeUse([url]) } catch { blockers.append(error.localizedDescription) }
            }
        }
        let evidence = GitWorktreeEvidence(root: root, pointer: pointer, common: try Self.identity(common), admin: try Self.identity(admin),
            listing: listing, status: status, upstream: upstream, ahead: ahead, unique: unique)
        guard try Self.identity(url) == root, try Self.identity(pointerURL) == pointer,
              Self.readGit(at: url, arguments: ["rev-parse", "--verify", "HEAD"]).map(Self.trimLine) == head else { throw GitWorktreeError.changed }
        return GitWorktreeReview(candidate: candidate, commonDirectory: common, gitDirectory: admin,
            isMainWorktree: isMain, branch: listing.branch, head: head, changedEntries: changes, aheadOfUpstream: ahead,
            upstream: upstream, commitsOnlyHere: unique, lockReason: listing.locked, prunableReason: listing.prunable,
            removalBlockers: blockers, evidence: evidence, tree: tree)
    }

    public func remove(reviewed: GitWorktreeReview, excludedFolders: [String] = []) async throws {
        guard !removing else { throw GitWorktreeError.unsafe("another worktree removal is in progress") }
        guard reviewed.canRemove, reviewed.tree != nil else { throw GitWorktreeError.unsafe(reviewed.removalBlockers.joined(separator: " ")) }
        removing = true; defer { removing = false }
        let fresh = try await inspect(candidate: reviewed.candidate, excludedFolders: excludedFolders)
        guard fresh.canRemove, fresh.commonDirectory == reviewed.commonDirectory, fresh.gitDirectory == reviewed.gitDirectory,
              fresh.evidence == reviewed.evidence, fresh.tree == reviewed.tree else { throw GitWorktreeError.changed }
        try Task.checkCancellation()
        try activeUse([try Self.canonical(reviewed.candidate.url)])
        guard try Self.identity(try Self.canonical(reviewed.candidate.url)) == reviewed.evidence.root,
              try Self.identity(reviewed.commonDirectory) == reviewed.evidence.common,
              try Self.identity(reviewed.gitDirectory) == reviewed.evidence.admin else { throw GitWorktreeError.changed }
        try Self.removeWithGit(common: reviewed.commonDirectory, worktree: try Self.canonical(reviewed.candidate.url))
    }

    private static func readGit(at url: URL, arguments: [String]) -> String? {
        // No promisor-remote fetches and no replacement-object history that could
        // hide detached commits. Older Git fails closed instead of fetching.
        GitCheckoutProbe.runLocal(at: url, arguments: ["--no-lazy-fetch", "--no-replace-objects"] + arguments)
    }
    private static func gitPath(at url: URL, option: String) throws -> URL {
        guard let output = Self.readGit(at: url, arguments: ["rev-parse", "--path-format=absolute", option]) else { throw GitWorktreeError.unknown("Git could not resolve " + option) }
        return try canonical(pathOutput(output))
    }
    private static func pathOutput(_ output: String) throws -> URL {
        let path = trimLine(output)
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else { throw GitWorktreeError.unknown("Git returned an invalid or multiline path") }
        return URL(fileURLWithPath: path)
    }
    private static func trimLine(_ text: String) -> String { text.hasSuffix("\n") ? String(text.dropLast()) : text }
    private static func count(_ output: String?) -> Int? {
        guard let value = output.map(trimLine), !value.isEmpty, value.allSatisfy(\.isNumber), let result = Int(value), result >= 0 else { return nil }; return result
    }
    private static func validObjectID(_ text: String) -> Bool { [40, 64].contains(text.count) && text.allSatisfy { $0.isHexDigit } }
    private static func validStatus(_ text: String) -> Bool {
        if text.isEmpty { return true }
        guard text.last == "\0" else { return false }
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.utf8.count >= 4, field.dropFirst(2).first == " " else { return false }
            let flags = field.prefix(2)
            if flags.contains("R") || flags.contains("C") { index += 1; guard index < fields.count else { return false } }
            index += 1
        }
        return true
    }
    static func parseList(_ text: String) throws -> [WorktreeListing] {
        guard text.hasSuffix("\0\0") else { throw GitWorktreeError.unknown("Git returned an incomplete worktree list") }
        var rows: [WorktreeListing] = [], fields: [String] = []
        func finish() throws {
            guard let first = fields.first, first.hasPrefix("worktree ") else { throw GitWorktreeError.unknown("invalid worktree registration") }
            var head: String?, branch: String?, lock: String?, prune: String?
            var detached = false, bare = false, seen = Set<String>()
            for field in fields.dropFirst() {
                let key = String(field.prefix { $0 != " " })
                guard seen.insert(key).inserted else { throw GitWorktreeError.unknown("duplicate worktree field") }
                switch key {
                case "HEAD": head = String(field.dropFirst(5))
                case "branch": branch = String(field.dropFirst(7))
                case "detached": detached = true
                case "bare": bare = true
                case "locked": lock = field == key ? "" : String(field.dropFirst(7))
                case "prunable": prune = field == key ? "" : String(field.dropFirst(9))
                default: throw GitWorktreeError.unknown("unsupported worktree registration field: " + key)
                }
            }
            guard !(detached && branch != nil), branch.map({ $0.hasPrefix("refs/heads/") }) ?? true else { throw GitWorktreeError.unknown("invalid worktree branch") }
            rows.append(WorktreeListing(path: String(first.dropFirst(9)), head: head, branch: branch, detached: detached, bare: bare, locked: lock, prunable: prune, main: rows.isEmpty))
            fields = []
        }
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty { if !fields.isEmpty { try finish() } }
            else { fields.append(String(field)) }
        }
        guard !rows.isEmpty else { throw GitWorktreeError.unknown("empty worktree list") }; return rows
    }
    private static func identity(_ url: URL) throws -> WorktreeIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw GitWorktreeError.unsafe("missing, unreadable or symbolic-link metadata at " + url.path) }
        return WorktreeIdentity(info)
    }
    private static func canonical(_ url: URL) throws -> URL {
        let path = url.path
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), let resolved = realpath(path, nil) else { throw GitWorktreeError.unsafe("path is unavailable") }
        defer { free(resolved) }
        let physical = String(cString: resolved)
        // These are macOS's fixed system aliases, not user-controlled links.
        guard physical == systemAliases(path) else { throw GitWorktreeError.unsafe("the path traverses a symbolic link") }
        return URL(fileURLWithPath: physical)
    }
    private static func systemAliases(_ path: String) -> String {
        [("/var", "/private/var"), ("/tmp", "/private/tmp")].reduce(path) { value, alias in
            value == alias.0 || value.hasPrefix(alias.0 + "/") ? alias.1 + value.dropFirst(alias.0.count) : value
        }
    }
    private static func treeFingerprint(_ scan: ScanResult) throws -> Data {
        struct Entry { let path: String; let node: DiskNode }
        let entries = scan.nodes.map { Entry(path: scan.url(for: $0.id).path, node: $0) }.sorted { $0.path < $1.path }
        var hash = SHA256()
        for item in entries {
            try Task.checkCancellation()
            let n = item.node
            let record = "\(item.path)\0\(n.device):\(n.inode):\(n.isDirectory):\(n.isSymlink):\(n.logicalBytes):\(n.allocatedBytes):\(n.modified.timeIntervalSince1970)\0"
            hash.update(data: Data(record.utf8))
        }
        return Data(hash.finalize())
    }
    private static func removeWithGit(common: URL, worktree: URL) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-lazy-fetch", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null", "--git-dir", common.path, "worktree", "remove", "--", worktree.path]
        process.currentDirectoryURL = common
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_LITERAL_PATHSPECS": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"]
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        try process.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { process.terminate(); process.waitUntilExit(); throw GitWorktreeError.command("output could not be bounded") }
        let deadline = Date().addingTimeInterval(30)
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16_384), stopped: Date?, cancelled = false
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(min(count, max(0, 65_536 - output.count)))) }
            else if !process.isRunning { break }
            if Task.isCancelled || Date() > deadline {
                cancelled = true
                if stopped == nil { process.terminate(); stopped = Date() }
                else if Date().timeIntervalSince(stopped!) > 0.25 { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            if count <= 0 { usleep(10_000) }
        }
        process.waitUntilExit(); try? pipe.fileHandleForReading.close()
        if cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw GitWorktreeError.command("the command timed out; removal may be partial. Inspect this checkout and its Git registration.")
        }
        guard process.terminationStatus == 0 else { throw GitWorktreeError.command(String(decoding: output, as: UTF8.self)) }
        var remaining = stat()
        guard lstat(worktree.path, &remaining) != 0, errno == ENOENT else { throw GitWorktreeError.command("Git exited successfully but the checkout path remains; inspect it manually") }
    }
}
