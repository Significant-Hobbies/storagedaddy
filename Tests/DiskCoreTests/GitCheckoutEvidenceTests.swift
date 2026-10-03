import XCTest
@testable import DiskCore

final class GitCheckoutEvidenceTests: XCTestCase {
    func testRenamesAreOneChangeAndMissingUpstreamStaysUnknown() {
        let result = GitCheckoutProbe.collect(at: URL(fileURLWithPath: "/fixture")) { _, args in
            switch args.first {
            case "status": return " M modified.swift\0R  new.swift\0old.swift\0?? new-file\0"
            case "rev-list": return nil
            case "stash": return "stash@{0}\nstash@{1}\n"
            default: XCTFail("Unexpected command"); return nil
            }
        }
        XCTAssertEqual(result.changedEntries, 3)
        XCTAssertNil(result.unpushedCommits)
        XCTAssertEqual(result.stashes, 2)
    }
    func testFailedChecksAreUnknownAndSuccessfulEmptyOutputIsZero() {
        let failed = GitCheckoutProbe.collect(at: URL(fileURLWithPath: "/fixture")) { _, _ in nil }
        XCTAssertNil(failed.changedEntries); XCTAssertNil(failed.stashes)
        let clean = GitCheckoutProbe.collect(at: URL(fileURLWithPath: "/fixture")) { _, args in args.first == "rev-list" ? "0\n" : "" }
        XCTAssertEqual(clean.changedEntries, 0); XCTAssertEqual(clean.unpushedCommits, 0); XCTAssertEqual(clean.stashes, 0)
    }
    func testLocalProbeOfNonRepositoryFailsClosed() {
        let result = GitCheckoutProbe.collect(at: FileManager.default.temporaryDirectory)
        XCTAssertNil(result.changedEntries); XCTAssertNil(result.unpushedCommits); XCTAssertNil(result.stashes)
    }
}
