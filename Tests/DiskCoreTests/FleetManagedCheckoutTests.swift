import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class FleetManagedCheckoutTests: XCTestCase {
    func testOnlyReviewedRetiredIDIsClosedAndNewBlockersAreRespected() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let registry = FleetManagedCheckout.registry(home: home)
        let checkout = registry.appendingPathComponent("retired/fixture")
        let manifests = registry.appendingPathComponent("manifests")
        let bin = home.appendingPathComponent(".local/bin")
        for url in [checkout, manifests, bin] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let record = ["id": "fixture", "path": checkout.path, "state": "closed"]
        try JSONEncoder().encode(record).write(to: manifests.appendingPathComponent("fixture.json"))
        let cli = bin.appendingPathComponent("fleet-workspace")
        let script = """
        #!/bin/sh
        set -eu
        test "$1" = close && test "$2" = --id && test "$3" = fixture && test "$4" = --root && test "$5" -ef "$PWD"
        if test "${6-}" = --dry-run; then
          action=delete-worktree
          if test -f blocked; then action=keep; fi
          printf '{"action":"%s","id":"fixture","path":"%s/retired/fixture","state":"closed","head":"abc","blockers":[]}' "$action" "$5"
        else
          /bin/rmdir "$PWD/retired/fixture"
          printf '{"action":"delete-worktree"}'
        fi
        """
        try Data(script.utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var metadata = stat()
        XCTAssertEqual(lstat(checkout.path, &metadata), 0)
        let candidate = GitWorktreeCandidate(url: checkout, allocatedBytes: 4096, device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
        let review = try FleetManagedCheckout.inspect(candidate, exclusions: [], home: home)
        XCTAssertTrue(review.eligible)
        XCTAssertThrowsError(try FleetManagedCheckout.remove(review, exclusions: [checkout.path], home: home))
        let blocker = registry.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        XCTAssertThrowsError(try FleetManagedCheckout.remove(review, exclusions: [], home: home))
        XCTAssertTrue(fm.fileExists(atPath: checkout.path))
        try fm.removeItem(at: blocker)
        try FleetManagedCheckout.remove(review, exclusions: [], home: home)
        XCTAssertFalse(fm.fileExists(atPath: checkout.path))
    }
}
