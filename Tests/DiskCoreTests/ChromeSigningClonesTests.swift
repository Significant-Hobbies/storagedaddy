import Darwin
import Foundation
import XCTest
@testable import DiskCore

final class ChromeSigningClonesTests: XCTestCase {
    private let store = "/private/var/folders/zz/fixture/X/com.google.Chrome.code_sign_clone"

    func testRecognitionRequiresTheChromeSigningLocation() throws {
        XCTAssertEqual(ChromeSigningClones.location(path: store), .store)
        XCTAssertEqual(ChromeSigningClones.location(path: store + "/code_sign_clone.Abc123"), .copy)
        XCTAssertEqual(ChromeSigningClones.location(path: "/System/Volumes/Data" + store), .store)
        XCTAssertEqual(ChromeSigningClones.location(path: store.replacingOccurrences(of: "/private/var", with: "/var")), .store)
        for path in ["/Users/test/Downloads/com.google.Chrome.code_sign_clone", store.replacingOccurrences(of: "/X/", with: "/T/"), store + "-backup"] {
            XCTAssertNil(ChromeSigningClones.location(path: path))
        }
        XCTAssertEqual(ChromeSigningClones.location(path: store + "/code_sign_clone.Abc123/Google Chrome.app.bundle/Contents"), .contents)
        XCTAssertThrowsError(try ChromeSigningClones.validateForCleanup(at: URL(fileURLWithPath: store)))
        XCTAssertThrowsError(try ChromeSigningClones.validateForCleanup(at: URL(fileURLWithPath: store + "/code_sign_clone.Abc123/Google Chrome.app.bundle")))
        let scan = ScanResult(rootPath: store, nodes: [DiskNode(id: 0, parent: nil, name: "com.google.Chrome.code_sign_clone", isDirectory: true)])
        XCTAssertEqual(FolderArchetypes.assess(scan, folderID: 0)?.archetype, .appSigningCopies)
    }

    func testOnlyOldVerifiedCopiesWithChromeQuitPass() throws {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { false })
        XCTAssertThrowsError(try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { true }))
        XCTAssertThrowsError(try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { throw POSIXError(.EIO) }))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fixture.copy.path)
        XCTAssertThrowsError(try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { false }))
    }

    func testZeroAttributedCopiesRemainReviewableWithoutSelectingBundleFiles() {
        let scan = ScanResult(rootPath: store, nodes: [
            DiskNode(id: 0, parent: nil, name: "com.google.Chrome.code_sign_clone", isDirectory: true, children: [1, 2, 3]),
            DiskNode(id: 1, parent: 0, name: "code_sign_clone.Abc123", isDirectory: true, allocatedBytes: 100),
            DiskNode(id: 2, parent: 0, name: "code_sign_clone.Def456", isDirectory: true, allocatedBytes: 0),
            DiskNode(id: 3, parent: 0, name: "other-original-work", isDirectory: true)
        ])
        XCTAssertEqual(ChromeSigningClones.copyIDs(in: scan, storeID: 0), [1, 2])
        XCTAssertEqual(ChromeSigningClones.copyIDs(in: scan, storeID: 2), [])
    }

    func testOpenFrameworkUnexpectedContentsAndSymlinksAreKept() throws {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let descriptor = open(fixture.binary.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertThrowsError(try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { false }))
        close(descriptor)
        let extra = fixture.copy.appendingPathComponent("original-work.txt")
        try Data([1]).write(to: extra)
        try makeOld(fixture.copy)
        XCTAssertThrowsError(try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { false }))
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: fixture.binary)
        XCTAssertEqual(symlink("/dev/null", fixture.binary.path), 0)
        try makeOld(fixture.copy)
        XCTAssertThrowsError(try ChromeSigningClones.validateCopy(at: fixture.copy, now: Date(), chromeIsRunning: { false }))
    }

    private func copyFixture() throws -> (root: URL, copy: URL, binary: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddy-SigningCopy-\(UUID().uuidString)")
        let copy = root.appendingPathComponent("code_sign_clone.Abc123")
        let binary = copy.appendingPathComponent("Google Chrome.app.bundle/Contents/Frameworks/Google Chrome Framework.framework/Versions/123.0/Google Chrome Framework")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: binary)
        try makeOld(copy)
        return (root, copy, binary)
    }

    private func makeOld(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: url.path)
    }
}
