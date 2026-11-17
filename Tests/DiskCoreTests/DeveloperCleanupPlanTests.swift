import Foundation
import Testing
@testable import DiskCore

struct DeveloperCleanupPlanTests {
    @Test func selectsMeasuredArtifactsAndKeepsBusyOrReplacedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("developer-cleanup-\(UUID())")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        func project(_ name: String) throws -> URL {
            let project = root.appendingPathComponent(name)
            let dependencies = project.appendingPathComponent("node_modules")
            try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
            try Data(repeating: 1, count: 4_096).write(to: dependencies.appendingPathComponent("module.js"))
            return dependencies
        }
        let idle = try project("idle")
        let openedLater = try project("opened-later")
        let replaced = try project("replaced")
        let openedDuringReview = try project("busy")
        let blocked = try project("excluded")
        let unchecked = try project("unchecked")
        let withoutManifest = try project("no-manifest")
        try fm.removeItem(at: withoutManifest.deletingLastPathComponent().appendingPathComponent("package.json"))
        let build = root.appendingPathComponent("swift/.build")
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: build.deletingLastPathComponent().appendingPathComponent("Package.swift"))
        try Data(repeating: 1, count: 4_096).write(to: build.appendingPathComponent("build.out"))
        let unrelated = root.appendingPathComponent("large-source.bin")
        try Data(repeating: 2, count: 8_192).write(to: unrelated)
        let handle = try FileHandle(forReadingFrom: openedDuringReview.appendingPathComponent("module.js"))
        defer { try? handle.close() }
        let full = try await DiskScanner.scan(root: root)
        let plan = try await DeveloperCleanupPlan.prepare(root: root, excluding: [blocked.appendingPathComponent("module.js").path])
        let items = Dictionary(uniqueKeysWithValues: plan.items.map { (URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent, $0) })
        #expect(Set(items.keys) == ["idle", "opened-later", "replaced", "busy", "excluded", "unchecked", "swift"])
        let first = try #require(items["idle"])
        let reference = try #require(full.nodes.first { $0.name == "node_modules" && full.url(for: $0.id).deletingLastPathComponent().lastPathComponent == "idle" })
        #expect(first.allocatedBytes == reference.allocatedBytes)
        #expect(items["busy"]?.keptReason?.contains("In use") == true)
        #expect(items["excluded"]?.keptReason != nil)
        #expect(items["swift"]?.canDeletePermanently == false)

        let lateHandle = try FileHandle(forReadingFrom: openedLater.appendingPathComponent("module.js"))
        defer { try? lateHandle.close() }
        let held = replaced.deletingLastPathComponent().appendingPathComponent("original")
        try fm.moveItem(at: replaced, to: held)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        let later = try #require(items["opened-later"])
        let changed = try #require(items["replaced"])
        let result = await plan.clean(ids: [first.id, later.id, changed.id], permanently: true)
        #expect(result.deleted == [first.id])
        #expect(Set(result.kept.keys) == [later.id, changed.id])
        #expect(!fm.fileExists(atPath: idle.path))
        for url in [openedLater, replaced, held, openedDuringReview, blocked, unchecked, withoutManifest, build, unrelated,
                    idle.deletingLastPathComponent().appendingPathComponent("package.json")] {
            #expect(fm.fileExists(atPath: url.path))
        }
    }
}
