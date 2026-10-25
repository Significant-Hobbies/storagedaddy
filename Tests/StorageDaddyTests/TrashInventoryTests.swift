import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

@MainActor @Suite(.serialized)
struct TrashInventoryTests {
    private func wait(_ model: TrashInventoryModel) async throws {
        for _ in 0..<200 {
            if !model.loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Trash measurement did not finish")
    }

    @Test func measuresNestedTrashAndRefreshesAfterChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: nested.appendingPathComponent("file.bin"))
        let model = TrashInventoryModel(trash: root)
        #expect(model.sizeLabel == "Not measured")
        #expect(!Workspace.cleanup.requiresScan)
        model.refresh(excludedFolders: [])
        #expect(model.sizeLabel == "Measuring…")
        try await wait(model)
        #expect(model.items.map(\.name) == ["folder"])
        #expect(model.allocatedBytes > 0)
        #expect(model.sizeLabel == DiskFormat.bytes(model.allocatedBytes))
        #expect(model.error == nil)
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("another.bin"))
        model.refresh(excludedFolders: [])
        try await wait(model)
        #expect(model.items.count == 2)
        #expect(model.scan?.skipped == 0)
    }

    @Test func distinguishesEmptyTrashFromUnavailableSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = TrashInventoryModel(trash: root)
        model.refresh(excludedFolders: [])
        try await wait(model)
        #expect(model.allocatedBytes == 0)
        #expect(model.sizeLabel == DiskFormat.bytes(0))
        #expect(model.error == nil)
        model.refresh(excludedFolders: [root.path])
        try await wait(model)
        #expect(model.scan == nil)
        #expect(model.error != nil)
        #expect(model.sizeLabel == "Size unavailable")
    }

    @Test func labelsSkippedContentsAsPartial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data([1]).write(to: kept.appendingPathComponent("file.bin"))
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("readable.bin"))
        let model = TrashInventoryModel(trash: root)
        model.refresh(excludedFolders: [kept.path])
        try await wait(model)
        #expect(model.scan?.skipped == 1)
        #expect(model.sizeLabel.hasSuffix(" · partial"))
        #expect(model.items.map(\.name) == ["readable.bin"])
    }
}
