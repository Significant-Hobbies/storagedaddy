import Foundation
import Testing
@testable import DiskCore

struct DeveloperCleanupPlanTests {
    @Test func keepsNestedDependenciesWithinTheirReviewedProjectContainer() async throws {
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appendingPathComponent("developer-dependency-root-\(UUID())")
        defer { try? fm.removeItem(at: project) }
        let dependencies = project.appendingPathComponent("node_modules")
        let manifest = project.appendingPathComponent("package.json")
        func installPackage(in container: URL) throws -> URL {
            let package = container.appendingPathComponent("installed-package")
            let nested = package.appendingPathComponent("node_modules")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: package.appendingPathComponent("package.json"))
            try Data("fixture".utf8).write(to: nested.appendingPathComponent("entry.js"))
            return package
        }
        func expectDenied(_ scope: URL) async {
            do {
                _ = try await DeveloperCleanupPlan.prepare(root: scope)
                Issue.record("A dependency scope must not offer its nested dependencies for cleanup")
            } catch {
                #expect(error.localizedDescription.contains("project folder"))
            }
        }

        let installedPackage = try installPackage(in: dependencies)
        try Data("{}".utf8).write(to: manifest)
        let projectPlan = try await DeveloperCleanupPlan.prepare(root: project)
        let item = try #require(projectPlan.items.first)
        #expect(projectPlan.items.count == 1)
        #expect(item.path == dependencies.resolvingSymlinksInPath().path)
        #expect(item.keptReason == nil && item.canDeletePermanently)
        await expectDenied(dependencies)
        await expectDenied(installedPackage)

        try fm.removeItem(at: manifest)
        await expectDenied(dependencies)
        await expectDenied(installedPackage)

        let globalDependencies = project.appendingPathComponent("custom-prefix/lib/node_modules")
        let globalPackage = try installPackage(in: globalDependencies)
        await expectDenied(globalDependencies)
        await expectDenied(globalPackage)
    }

    @Test func keepsGitCheckoutAddedInsideDependenciesAfterReview() async throws {
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appendingPathComponent("developer-late-repository-\(UUID())")
        defer { try? fm.removeItem(at: project) }
        let dependencies = project.appendingPathComponent("node_modules")
        let checkout = dependencies.appendingPathComponent("installed-package/nested")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        let manifest = project.appendingPathComponent("package.json")
        let source = checkout.appendingPathComponent("source.js")
        try Data("{}".utf8).write(to: manifest)
        try Data("synthetic local source".utf8).write(to: source)
        let plan = try await DeveloperCleanupPlan.prepare(root: project)
        let item = try #require(plan.items.first)
        try #require(item.keptReason == nil && item.canDeletePermanently)

        let git = checkout.appendingPathComponent(".git")
        try fm.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        let outcome = await plan.clean(ids: [item.id], permanently: true)
        #expect(outcome.deleted.isEmpty && outcome.trashed.isEmpty)
        #expect(outcome.kept[item.id]?.contains("Git checkout") == true)
        #expect(fm.fileExists(atPath: git.path))
        #expect(fm.fileExists(atPath: source.path))
        #expect(fm.fileExists(atPath: manifest.path))
    }

    @Test func discoversMetroCachesInClaudeWorktreesAndKeepsBusyProjects() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("developer-metro-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let worktree = root.appendingPathComponent("repo/.claude/worktrees/agent")
        let metadata = root.appendingPathComponent("repo/.claude/projects/agent")
        let other = root.appendingPathComponent("repo/unrelated")
        for (location, hasMetroConfig) in [(worktree, true), (metadata, true), (other, false)] {
            let cache = location.appendingPathComponent(".metro-cache")
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: location.appendingPathComponent("package.json"))
            if hasMetroConfig {
                try Data().write(to: location.appendingPathComponent("metro.config.js"))
            }
            try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("bundle"))
        }
        let plan = try await DeveloperCleanupPlan.prepare(root: root)
        #expect(plan.items.count == 1)
        let item = try #require(plan.items.first)
        #expect(item.path.hasSuffix("/repo/.claude/worktrees/agent/.metro-cache"))
        #expect(item.allocatedBytes == 4096)
        #expect(item.keptReason == nil)
        #expect(!item.canDeletePermanently)

        let handle = try FileHandle(forReadingFrom: worktree.appendingPathComponent("package.json"))
        defer { try? handle.close() }
        let busy = try await DeveloperCleanupPlan.prepare(root: root)
        #expect(busy.items.first?.keptReason?.contains("Metro project in use") == true)
        let result = await plan.clean(ids: [item.id], permanently: true)
        #expect(result.kept[item.id]?.contains("Metro project is in use") == true)
        #expect(fm.fileExists(atPath: item.path))
    }

    @Test func findsKnownCacheLocationsAndHoldsLockManagedCaches() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("developer-cache-home-\(UUID())")
        let caches = home.appendingPathComponent(".cache")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        for name in ["uv", "go-build", "unknown"] {
            let folder = caches.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("fixture"))
        }
        let plan = try await DeveloperCleanupPlan.prepare(root: caches, home: home.path)
        let names = Dictionary(uniqueKeysWithValues: plan.items.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
        #expect(Set(names.keys) == ["uv", "go-build"])
        #expect(names["uv"]?.keptReason?.contains("uv cache clean") == true)
        #expect(names["go-build"]?.keptReason?.contains("cache cleaner") == true)
        #expect(names["go-build"]?.allocatedBytes == 4096)
    }

    @Test func reportsWhyAnExcludedRootWasSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("developer-cleanup-excluded-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await DeveloperCleanupPlan.prepare(root: root, excluding: [root.path])
            Issue.record("An excluded root should not produce a cleanup review")
        } catch {
            #expect(error.localizedDescription == "This folder was excluded by folder settings.")
        }
    }

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
        let laterName = "opened-later-café-👨‍👩‍👧"
        let busyName = "busy-café\tproject"
        let openedLater = try project(laterName)
        let replaced = try project("replaced")
        let openedDuringReview = try project(busyName)
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
        #expect(Set(items.keys) == ["idle", laterName, "replaced", busyName, "excluded", "unchecked", "swift"])
        let first = try #require(items["idle"])
        let reference = try #require(full.nodes.first { $0.name == "node_modules" && full.url(for: $0.id).deletingLastPathComponent().lastPathComponent == "idle" })
        #expect(first.allocatedBytes == reference.allocatedBytes)
        #expect(items[busyName]?.keptReason?.contains("In use") == true)
        #expect(items["excluded"]?.keptReason != nil)
        #expect(items["swift"]?.canDeletePermanently == false)

        let lateHandle = try FileHandle(forReadingFrom: openedLater.appendingPathComponent("module.js"))
        defer { try? lateHandle.close() }
        let held = replaced.deletingLastPathComponent().appendingPathComponent("original")
        try fm.moveItem(at: replaced, to: held)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        let later = try #require(items[laterName])
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
