import XCTest
@testable import DiskCore

final class FolderArchetypesTests: XCTestCase {
    private func scan(_ path: String, markers: [(String, Bool)] = []) -> ScanResult {
        var root = DiskNode(id: 0, parent: nil, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: true, children: markers.indices.map { $0 + 1 })
        root.isScanIncomplete = false
        let children = markers.enumerated().map { index, marker in
            DiskNode(id: index + 1, parent: 0, name: marker.0, isDirectory: marker.1)
        }
        return ScanResult(rootPath: path, nodes: [root] + children)
    }

    func testProjectMarkersSeparateSourceFromDependencyAndBuildGuidance() throws {
        var fixture = scan("/Users/test/Desktop/project", markers: [("package.json", false), ("node_modules", true), ("dist", true)])
        let project = try XCTUnwrap(FolderArchetypes.assess(fixture, folderID: 0))
        XCTAssertEqual(project.archetype, .project)
        XCTAssertTrue(project.evidence.contains("package.json"))
        XCTAssertTrue(project.explanation.contains("unpublished work"))
        XCTAssertEqual(FolderArchetypes.assess(fixture, folderID: 2)?.archetype, .dependencies)
        XCTAssertEqual(FolderArchetypes.assess(fixture, folderID: 3)?.archetype, .buildOutputs)

        fixture.nodes[1].isSymlink = true
        XCTAssertEqual(FolderArchetypes.assess(fixture, folderID: 0)?.archetype, .personalFiles)
        XCTAssertEqual(FolderArchetypes.assess(fixture, folderID: 3, category: .buildOutputs)?.archetype, .personalFiles)
    }

    func testGitWorktreeMarkerCanBeAFileButManifestCannotBeDirectory() {
        XCTAssertEqual(FolderArchetypes.assess(scan("/workspace/project", markers: [(".git", false)]), folderID: 0)?.archetype, .project)
        XCTAssertEqual(FolderArchetypes.assess(scan("/workspace/project", markers: [("Cargo.toml", false)]), folderID: 0)?.archetype, .project)
        XCTAssertEqual(FolderArchetypes.assess(scan("/workspace/project", markers: [("package.json", true)]), folderID: 0)?.archetype, .unknown)
        XCTAssertEqual(FolderArchetypes.assess(scan("/workspace/project/.git/objects"), folderID: 0)?.archetype, .gitMetadata)
    }

    func testAmbiguousNamesDoNotEstablishCachesBuildsOrPersistentStores() {
        for name in ["cache", "build", "target", "models", "vendor", "orbstack", "Containers"] {
            XCTAssertEqual(FolderArchetypes.assess(scan("/workspace/\(name)"), folderID: 0, category: name == "build" ? .buildOutputs : nil)?.archetype, .unknown, name)
        }
        XCTAssertEqual(FolderArchetypes.assess(scan("/Users/test/copy/Library/Caches/uv"), folderID: 0)?.archetype, .unknown)
        XCTAssertEqual(FolderArchetypes.assess(scan("/System/Volumes/Data"), folderID: 0)?.archetype, .unknown)
    }

    func testKnownLocationsReceiveDifferentGuidanceIncludingDataVolumeAlias() throws {
        let examples: [(String, FolderArchetype)] = [
            ("/Users/test/Library/Caches/uv", .cache),
            ("/Users/test/.cache/huggingface/hub", .models),
            ("/Users/test/.ollama/models", .models),
            ("/Users/test/Library/Application Support/Editor", .appData),
            ("/Users/test/Library/Containers/editor/Data", .appData),
            ("/Users/test/Library/Group Containers/editor", .appData),
            ("/Users/test/.codex/sessions/2026", .agentHistory),
            ("/Users/test/.claude/projects/workspace", .agentHistory),
            ("/Users/test/Downloads", .personalFiles),
            ("/Users/test/Library/Developer/Xcode/DerivedData", .buildOutputs),
            ("/Applications/Editor.app/Contents", .application),
            ("/System/Library", .systemStorage),
            ("/private/var/vm", .systemStorage),
        ]
        for (path, expected) in examples {
            let result = try XCTUnwrap(FolderArchetypes.assess(scan(path), folderID: 0))
            XCTAssertEqual(result.archetype, expected, path)
            XCTAssertEqual(FolderArchetypes.assess(scan("/System/Volumes/Data" + path), folderID: 0)?.archetype, expected, path)
            XCTAssertFalse(result.evidence.isEmpty)
        }
    }

    func testVirtualMachineOwnershipOverridesNestedCacheOrProjectHints() throws {
        for path in ["/Users/test/Library/Group Containers/HUAQ24HBR6.dev.orbstack", "/Users/test/Library/Containers/com.docker.docker/Data/cache", "/Users/test/.orbstack/data", "/Users/test/Machines/Linux.utm/Data"] {
            let result = try XCTUnwrap(FolderArchetypes.assess(scan(path, markers: [("package.json", false)]), folderID: 0, category: .packageCaches))
            XCTAssertEqual(result.archetype, .virtualMachines)
            XCTAssertTrue(result.explanation.contains("databases and original work"))
            XCTAssertTrue(result.explanation.contains("compaction"))
        }
        XCTAssertEqual(FolderArchetypes.assess(scan("/Applications/Editor.app/Contents/node_modules"), folderID: 0, category: .nodeModules)?.archetype, .application)
    }

    func testUnreadableAndPartialFoldersKeepEvidenceLimitsVisible() throws {
        var fixture = scan("/Users/test/Library/Group Containers/HUAQ24HBR6.dev.orbstack")
        fixture.nodes[0].isContentsUnreadable = true
        fixture.nodes[0].isScanIncomplete = true
        let unreadable = try XCTUnwrap(FolderArchetypes.assess(fixture, folderID: 0))
        XCTAssertEqual(unreadable.archetype, .virtualMachines)
        XCTAssertTrue(unreadable.coverage.contains("zero size"))
        fixture.nodes[0].isContentsUnreadable = false
        XCTAssertTrue(try XCTUnwrap(FolderArchetypes.assess(fixture, folderID: 0)).coverage.contains("only scanned entries"))
        fixture.nodes[0].isScanIncomplete = nil
        XCTAssertTrue(try XCTUnwrap(FolderArchetypes.assess(fixture, folderID: 0)).coverage.contains("not recorded"))
    }

    func testNonfoldersAndSymlinksAreNotAssessed() {
        var fixture = scan("/workspace", markers: [("package.json", false)])
        XCTAssertNil(FolderArchetypes.assess(fixture, folderID: 1))
        XCTAssertNil(FolderArchetypes.assess(fixture, folderID: 2))
        fixture.nodes[0].isSymlink = true
        XCTAssertNil(FolderArchetypes.assess(fixture, folderID: 0))
    }

    func testAgentPromptCarriesRoleEvidenceAndMissingCoverageInsteadOfEmptyClaim() throws {
        var fixture = scan("/Users/test/Library/Group Containers/HUAQ24HBR6.dev.orbstack")
        fixture.nodes[0].isContentsUnreadable = true
        let assessment = try XCTUnwrap(FolderArchetypes.assess(fixture, folderID: 0))
        let prompt = FolderExplainer.prompt(path: fixture.rootPath, allocatedBytes: 0, logicalBytes: 0, children: 0, modified: .distantPast, assessment: assessment)
        XCTAssertTrue(prompt.contains(assessment.evidence))
        XCTAssertTrue(prompt.contains("compaction"))
        XCTAssertTrue(prompt.contains("Contents could not be read"))
        XCTAssertTrue(prompt.contains("zero scanned bytes as empty or unused"))
        XCTAssertTrue(prompt.contains("Do not delete or modify anything"))
    }
}
