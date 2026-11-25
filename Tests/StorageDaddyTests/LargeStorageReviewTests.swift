import Foundation
import Testing
@testable import StorageDaddy

struct LargeStorageReviewTests {
    @Test func measuresOnlyRecognizedLocationsAndHonorsExclusions() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let base = home.appendingPathComponent("Library/Application Support")
        let model = base.appendingPathComponent("Google/Chrome/OptGuideOnDeviceModel")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        // A sparse model must not be advertised at its logical size.
        let file = model.appendingPathComponent("weights.bin")
        try Data([1]).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 500_000_000)
        try handle.close()
        let link = base.appendingPathComponent("Cursor/snapshots")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: model)
        let small = try await LargeStorageEntry.discover(home: home, exclusions: [])
        #expect(small.isEmpty)
        let excluded = try await LargeStorageEntry.discover(home: home, exclusions: [file.path])
        #expect(excluded.isEmpty)
    }
}
