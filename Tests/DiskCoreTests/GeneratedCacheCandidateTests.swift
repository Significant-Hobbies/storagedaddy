import Foundation
import XCTest
@testable import DiskCore

final class GeneratedCacheCandidateTests: XCTestCase {
    func testTemporaryDerivedDataOffersOnlyBuildCachesAndRechecksReviewedContents() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let base = fixture.scratch.appendingPathComponent("sample-run.Ab34De/build")
        try fixture.derivedData(base)
        let candidate = base.appendingPathComponent("Build/Intermediates.noindex")
        let object = try fixture.write("Demo.build/file.o", under: candidate)
        let products = try fixture.write("Build/Products/kept.app/file", under: base)
        let evidence = try fixture.write("Logs/Build/last.xcactivitylog", under: base)
        let outside = try fixture.write("Outside/file", under: fixture.root)
        let alias = base.appendingPathComponent("ModuleCache.noindex")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside.deletingLastPathComponent())
        let initial = try await fixture.review()
        XCTAssertEqual(initial.map(\.url.path), [candidate.path])
        let item = try XCTUnwrap(initial.first)
        let change = try fixture.write("Demo.build/late.o", under: candidate)
        do { try await item.clean(excludedFolders: []); XCTFail("changed inventory accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: change.path))
        let second = try await fixture.review()
        let current = try XCTUnwrap(second.first)
        do { try await current.clean(excludedFolders: [object.path]); XCTFail("new exclusion ignored") } catch {}
        try await current.clean(excludedFolders: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        for kept in [outside, products, evidence, base.appendingPathComponent("info.plist")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        }
    }

    func testLiveWorkspaceIncompleteScanAndUnverifiedChromeCopiesStayOut() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let base = fixture.home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-123")
        try fixture.derivedData(base)
        _ = try fixture.write("ModuleCache.noindex/artifact.pcm", under: base)
        _ = try fixture.write("CompilationCache.noindex/.env", under: base)
        let open = try fixture.write("live", under: fixture.source)
        let handle = try FileHandle(forReadingFrom: open)
        let busy = try await fixture.review()
        XCTAssertTrue(busy.isEmpty)
        try handle.close()
        let store = fixture.root.appendingPathComponent("X/com.google.Chrome.code_sign_clone")
        for name in ["AAAAAA", "BBBBBB", "CCCCCC"] {
            let copy = store.appendingPathComponent("code_sign_clone." + name)
            _ = try fixture.write("Google Chrome.app.bundle/Contents/Info.plist", under: copy)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172800)], ofItemAtPath: copy.path)
        }
        let eligible = try await fixture.review(chromeStore: store)
        XCTAssertEqual(eligible.map(\.url.lastPathComponent), ["ModuleCache.noindex"])
    }

    func testRecognizesTemporaryMetroHashBucketsAndKeepsUnexpectedProjectFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let project = fixture.scratch.appendingPathComponent("app-run.Ab34De/webapp")
        let cache = project.appendingPathComponent(".metro-cache")
        _ = try fixture.write("package.json", under: project)
        _ = try fixture.write("metro.config.cjs", under: project)
        _ = try fixture.write("a7/" + String(repeating: "b", count: 68), under: cache)
        let first = try await fixture.review()
        XCTAssertEqual(first.map(\.url.path), [cache.path])
        let note = try fixture.write("research.md", under: cache)
        let after = try await fixture.review()
        XCTAssertTrue(after.isEmpty)
        let reviewed = try XCTUnwrap(first.first)
        do { try await reviewed.clean(excludedFolders: []); XCTFail("unexpected local file accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    }

    func testChromiumCacheRequiresRecognizedEntriesAndPreservesProfileHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let profile = fixture.home.appendingPathComponent("Library/Application Support/Linear")
        let cache = profile.appendingPathComponent("Cache/Cache_Data")
        _ = try fixture.write("index", under: cache)
        _ = try fixture.write("index-dir/the-real-index", under: cache)
        _ = try fixture.write("0123456789abcdef_0", under: cache)
        let profileData = try fixture.write("IndexedDB/preserved", under: profile)
        let first = try await fixture.review()
        let reviewed = try XCTUnwrap(first.first)
        let extra = try fixture.write("my-record.db", under: cache)
        do { try await reviewed.clean(excludedFolders: []); XCTFail("unrecognized file accepted") } catch {}
        try FileManager.default.removeItem(at: extra)
        let result = try await fixture.review()
        try await XCTUnwrap(result.first).clean(excludedFolders: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileData.path))
    }

    private struct Fixture {
        let root: URL
        var scratch: URL { root.appendingPathComponent("tmp") }
        var source: URL { root.appendingPathComponent("Source") }
        var home: URL { root.appendingPathComponent("Home") }
        init() throws {
            let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(path) }
            root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent(UUID().uuidString)
            for dir in [scratch, source, home] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        }
        func dispose() { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, under directory: URL) throws -> URL {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: 8192).write(to: file)
            return file
        }
        func derivedData(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let workspace = source.appendingPathComponent("Demo.xcworkspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            _ = try write("contents.xcworkspacedata", under: workspace)
            let data = try PropertyListSerialization.data(fromPropertyList: ["LastAccessedDate": Date(), "WorkspacePath": workspace.path],
                                                           format: .binary, options: 0)
            try data.write(to: url.appendingPathComponent("info.plist"))
        }
        func review(chromeStore: URL? = nil) async throws -> [GeneratedCacheCandidate] {
            try await GeneratedCacheCandidate.discover(home: home, temporary: scratch, chromeStore: chromeStore, excludedFolders: [])
        }
    }
}
