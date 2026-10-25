import Foundation
import XCTest
@testable import DiskCore

final class GitWorktreeManagerTests: XCTestCase {
    private struct Fixture { let root: URL; let main: URL; let linked: URL }
    @discardableResult private func git(_ cwd: URL, _ args: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-C", cwd.path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "GitFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
        return String(decoding: data, as: UTF8.self)
    }
    private func fixture(detached: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-fixture-" + UUID().uuidString)
        let main = root.appendingPathComponent("main"), linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try git(main, ["init", "-q", "--initial-branch=main"])
        try Data("*.cache\n.env*\n".utf8).write(to: main.appendingPathComponent(".gitignore"))
        try git(main, ["add", "--", ".gitignore"])
        try git(main, ["commit", "-q", "-m", "fixture"])
        try git(main, ["remote", "add", "origin", main.path])
        try git(main, ["fetch", "-q", "origin", "main"])
        if detached { try git(main, ["worktree", "add", "-q", "--detach", linked.path, "HEAD"]) }
        else {
            try git(main, ["worktree", "add", "-q", "-b", "feature", linked.path, "main"])
            try git(main, ["branch", "--set-upstream-to=origin/main", "feature"])
        }
        return Fixture(root: root, main: main, linked: linked)
    }
    private func candidates(_ fixture: Fixture) async throws -> [GitWorktreeCandidate] {
        try GitWorktreeManager.discover(in: await DiskScanner.scan(root: fixture.root))
    }
    private func linked(_ fixture: Fixture) async throws -> GitWorktreeCandidate {
        let all = try await candidates(fixture)
        return try XCTUnwrap(all.first { $0.url.lastPathComponent == "linked" })
    }

    func testCleanLinkedRemovalKeepsMainAndBranch() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        let candidate = try await linked(fixture)
        let review = try await manager.inspect(candidate: candidate)
        XCTAssertTrue(review.canRemove, review.removalBlockers.joined(separator: " "))
        XCTAssertEqual(review.changedEntries, 0); XCTAssertEqual(review.aheadOfUpstream, 0)
        try await manager.remove(reviewed: review)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.path))
        XCTAssertFalse(try git(fixture.main, ["rev-parse", "--verify", "refs/heads/feature"]).isEmpty)
    }
    func testMainAndLockedWorktreeAreRefused() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        let all = try await candidates(fixture)
        let main = try XCTUnwrap(all.first { $0.url.lastPathComponent == "main" })
        let mainReview = try await manager.inspect(candidate: main)
        XCTAssertTrue(mainReview.isMainWorktree); XCTAssertFalse(mainReview.canRemove)
        try git(fixture.main, ["worktree", "lock", "--reason", "Fixture lock", fixture.linked.path])
        let locked = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertEqual(locked.lockReason, "Fixture lock"); XCTAssertFalse(locked.canRemove)
    }
    func testDirtyAndNoUpstreamAreExplicitlyBlocked() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        try Data("fixture untracked".utf8).write(to: fixture.linked.appendingPathComponent("notes.txt"))
        let dirty = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertEqual(dirty.changedEntries, 1); XCTAssertFalse(dirty.canRemove)
        try git(fixture.main, ["branch", "--unset-upstream", "feature"])
        let noUpstream = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertNil(noUpstream.upstream); XCTAssertFalse(noUpstream.canRemove)
        XCTAssertTrue(noUpstream.removalBlockers.contains { $0.contains("upstream") })
    }
    func testAheadAndDetachedUniqueCommitsAreBlocked() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        try git(fixture.linked, ["commit", "-q", "--allow-empty", "-m", "unpushed fixture"])
        let ahead = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertEqual(ahead.aheadOfUpstream, 1); XCTAssertFalse(ahead.canRemove)
        let detachedFixture = try self.fixture(detached: true)
        try git(detachedFixture.linked, ["commit", "-q", "--allow-empty", "-m", "unique detached fixture"])
        let detached = try await manager.inspect(candidate: try await linked(detachedFixture))
        XCTAssertNil(detached.branch); XCTAssertEqual(detached.commitsOnlyHere, 1); XCTAssertFalse(detached.canRemove)
    }
    func testDetachedReachableCommitCanBeRemoved() async throws {
        let fixture = try fixture(detached: true)
        let manager = GitWorktreeManager(activeUse: { _ in })
        let review = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertTrue(review.canRemove, review.removalBlockers.joined(separator: " "))
        try await manager.remove(reviewed: review)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linked.path))
    }
    func testIgnoredSensitiveAndExcludedPathsProtectWorktree() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        try Data("fixture only".utf8).write(to: fixture.linked.appendingPathComponent(".env.fixture"))
        let candidate = try await linked(fixture)
        let review = try await manager.inspect(candidate: candidate)
        XCTAssertFalse(review.canRemove)
        do { _ = try await manager.inspect(candidate: candidate, excludedFolders: [fixture.linked.path]); XCTFail("excluded worktree accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
    }
    func testIgnoredFileChangeAfterReviewBlocksRemoval() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        let ignored = fixture.linked.appendingPathComponent("build.cache")
        try Data("old fixture cache".utf8).write(to: ignored)
        let review = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertTrue(review.canRemove, review.removalBlockers.joined(separator: " "))
        try Data("changed fixture cache".utf8).write(to: ignored)
        do { try await manager.remove(reviewed: review); XCTFail("stale ignored-file review accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
    }
    func testDiscoveryNeverAddsUnscannedSiblingWorktrees() async throws {
        let fixture = try fixture()
        let scan = try await DiskScanner.scan(root: fixture.main)
        let discovered = try GitWorktreeManager.discover(in: scan)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.url.lastPathComponent, "main")
    }
    func testActiveWorktreeCannotBeRemoved() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in throw GitWorktreeError.unsafe("fixture active process") })
        let review = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertFalse(review.canRemove)
        XCTAssertTrue(review.removalBlockers.contains { $0.contains("active process") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
    }
    func testLockAddedAfterReviewPreventsRemoval() async throws {
        let fixture = try fixture()
        let manager = GitWorktreeManager(activeUse: { _ in })
        let review = try await manager.inspect(candidate: try await linked(fixture))
        XCTAssertTrue(review.canRemove)
        try git(fixture.main, ["worktree", "lock", "--reason", "added after review", fixture.linked.path])
        do { try await manager.remove(reviewed: review); XCTFail("new lock ignored") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linked.path))
    }
    func testPorcelainParsingPreservesSpacesLocksAndPrunableReason() throws {
        let head = String(repeating: "a", count: 40)
        let rows = try GitWorktreeManager.parseList("worktree /main\0HEAD \(head)\0branch refs/heads/main\0\0worktree /linked path\0HEAD \(head)\0detached\0locked reason with spaces\0prunable missing checkout\0\0")
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows[0].main)
        XCTAssertEqual(rows[1].path, "/linked path"); XCTAssertEqual(rows[1].locked, "reason with spaces")
        XCTAssertEqual(rows[1].prunable, "missing checkout"); XCTAssertTrue(rows[1].detached)
    }
}
