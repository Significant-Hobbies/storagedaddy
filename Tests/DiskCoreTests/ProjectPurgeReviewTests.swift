import XCTest
@testable import DiskCore

final class ProjectPurgeReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { now.addingTimeInterval(-30 * 86400) }

    private func node(_ id: Int, _ parent: Int?, _ name: String, directory: Bool = true,
                      modified: Date? = nil, symlink: Bool = false) -> DiskNode {
        DiskNode(id: id, parent: parent, name: name, isDirectory: directory, isSymlink: symlink,
                 allocatedBytes: directory ? 0 : 100, modified: modified ?? old)
    }

    private func fixture(marker: String = "package.json", extra: [DiskNode] = []) -> ScanResult {
        ScanResult(rootPath: "/fixture/workspaces", nodes: [
            node(0, nil, "workspaces"), node(1, 0, "app"),
            node(2, 1, marker, directory: false), node(3, 1, "build"),
            node(4, 3, "output.bin", directory: false)
        ] + extra, started: now)
    }

    private func review(_ scan: ScanResult, probes: [Int: ProjectPurgeProbe] = [:]) -> [ProjectPurgeRecord] {
        let groups = DeveloperInsights.analyze(scan)
        let report = DeveloperReport.build(scan: scan, groups: groups)
        return ProjectPurgeReview.build(scan: scan, report: report, probes: probes, now: now)
    }

    private func proof(tracked: Set<Int> = [], checkouts: Set<Int> = []) -> ProjectPurgeProbe {
        ProjectPurgeProbe(git: .verified(trackedNodeIDs: tracked, checkoutRootIDs: checkouts),
                          rebuildability: [3: "Fixture: source and restoration procedure independently verified"])
    }

    func testMetadataIsCandidateNotProofAndSelectionStartsEmpty() throws {
        let record = try XCTUnwrap(review(fixture()).first)
        XCTAssertEqual(record.project.findingIDs, [3])
        XCTAssertEqual(record.candidateBytes, 100)
        XCTAssertTrue(record.artifacts[0].protections.contains(.unverifiedGit))
        XCTAssertTrue(record.artifacts[0].protections.contains(.unprovenRebuildability))
        XCTAssertTrue(record.stageableArtifactIDs.isEmpty)
        XCTAssertEqual(ProjectPurgeReview.stageableSelection([], in: [record]), [])
        let proven = review(fixture(), probes: [1: proof()])
        XCTAssertEqual(ProjectPurgeReview.stageableSelection([0, 1, 2, 3, 4], in: proven), [3])
        let gitOnly = review(fixture(), probes: [1: ProjectPurgeProbe(git: .verified(trackedNodeIDs: [], checkoutRootIDs: []))])
        XCTAssertTrue(gitOnly[0].stageableArtifactIDs.isEmpty)
    }

    func testDeploymentKeypairNamesProtectEntireArtifact() {
        for name in ["deployment-keypair.json", "keypair.json", "id_ed25519", "id_rsa", "deploy_key", "server.pem", "signing.p12", "private.key"] {
            let scan = fixture(extra: [node(5, 3, "deep"), node(6, 5, name, directory: false)])
            let record = review(scan, probes: [1: proof()])[0]
            XCTAssertTrue(record.artifacts[0].protections.contains(.deploymentKeypair), name)
            XCTAssertTrue(record.stageableArtifactIDs.isEmpty, name)
        }
    }

    func testNestedGitFileDirectoryAndInjectedCheckoutProtectArtifacts() {
        for directory in [true, false] {
            let scan = fixture(extra: [node(5, 3, "nested"), node(6, 5, ".git", directory: directory)])
            let records = review(scan, probes: [1: proof()])
            XCTAssertEqual(records.count, 1, "Vendored checkout is a protection, not another purge workspace")
            XCTAssertTrue(records[0].artifacts[0].protections.contains(.nestedCheckout))
        }
        let scan = fixture(extra: [node(5, 3, "checkout")])
        XCTAssertTrue(review(scan, probes: [1: proof(checkouts: [5])])[0].artifacts[0].protections.contains(.nestedCheckout))
    }

    func testAnyTrackedArtifactFileProtectsRootButSourceTrackingDoesNot() {
        XCTAssertTrue(review(fixture(), probes: [1: proof(tracked: [4])])[0].artifacts[0].protections.contains(.trackedFile))
        XCTAssertEqual(review(fixture(), probes: [1: proof(tracked: [2])])[0].stageableArtifactIDs, [3])
        for git: ProjectPurgeGitEvidence in [.unavailable, .failed("fixture timeout"), .verified(trackedNodeIDs: [999], checkoutRootIDs: [])] {
            let probe = ProjectPurgeProbe(git: git, rebuildability: [3: "Fixture proof"])
            XCTAssertTrue(review(fixture(), probes: [1: probe])[0].artifacts[0].protections.contains(.unverifiedGit))
        }
    }

    func testNewestWorkspaceModificationIncludesSourceAndNestedWorkspaces() {
        let recent = now.addingTimeInterval(-86400)
        let scan = fixture(extra: [node(5, 1, "src"), node(6, 5, "main.swift", directory: false, modified: recent)])
        let record = review(scan, probes: [1: proof()])[0]
        XCTAssertEqual(record.newestModified, recent)
        XCTAssertTrue(record.artifacts[0].protections.contains(.recentModification))
        XCTAssertTrue(record.stageableArtifactIDs.isEmpty)
        let nested = fixture(extra: [node(5, 1, "nested"), node(6, 5, "pubspec.yaml", directory: false),
                                     node(7, 5, "source.dart", directory: false, modified: recent)])
        XCTAssertTrue(review(nested).allSatisfy { $0.newestModified == recent })
    }

    func testUnknownIncompleteAndFutureModificationBlockBatch() {
        var unknown = fixture()
        unknown.nodes[4].modified = .distantPast
        XCTAssertNil(review(unknown, probes: [1: proof()])[0].newestModified)
        XCTAssertTrue(review(unknown, probes: [1: proof()])[0].protections.contains(.unknownModification))
        var skipped = fixture(); skipped.skipped = 1
        var failed = fixture(); failed.errors = ["fixture unreadable"]
        var truncated = fixture(); truncated.incompleteEvidenceTruncated = true
        var evidence = fixture(); evidence.incompleteEvidence = [ScanIncompleteEvidence(path: "/fixture/omitted", reason: "fixture")]
        for scan in [skipped, failed, truncated, evidence] {
            let record = review(scan, probes: [1: proof()])[0]
            XCTAssertTrue(record.protections.contains(.incompleteScan))
            XCTAssertTrue(record.stageableArtifactIDs.isEmpty)
        }
        var future = fixture(); future.nodes[4].modified = now.addingTimeInterval(10)
        XCTAssertTrue(review(future, probes: [1: proof()])[0].protections.contains(.recentModification))
        var boundary = fixture(); boundary.nodes[4].modified = now.addingTimeInterval(-7 * 86400)
        XCTAssertEqual(review(boundary, probes: [1: proof()])[0].stageableArtifactIDs, [3])
    }

    func testOverTwentySignaturesWithoutReadingBodies() {
        let names = ["package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Package.swift", "pom.xml",
                     "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
                     "composer.json", "Gemfile", "Podfile", "pubspec.yaml", "build.zig", "build.zig.zon",
                     "requirements.txt", "setup.py", "setup.cfg", "Pipfile", "CMakeLists.txt", "meson.build",
                     "mix.exs", "dune-project", "stack.yaml", "cabal.project", "project.clj", "deps.edn",
                     "game.uproject", "main.tf", "app.csproj", "app.fsproj", "app.sln"]
        XCTAssertGreaterThan(names.count, 20)
        for name in names {
            let record = review(fixture(marker: name)).first
            XCTAssertEqual(record?.id, 1, name)
            XCTAssertEqual(record?.project.findingIDs, [3], name)
            XCTAssertEqual(record?.artifacts.first?.finding.projectID, 1, name)
        }
    }

    func testUnityRequiresBothTypedDirectoriesAndRejectsFalseMarkers() {
        var scan = fixture(marker: "notes.txt")
        scan.nodes += [node(5, 1, "Assets")]
        XCTAssertTrue(review(scan).isEmpty)
        scan.nodes += [node(6, 1, "ProjectSettings")]
        XCTAssertEqual(review(scan).first?.signatures, ["Assets + ProjectSettings"])
        scan.nodes[6].isDirectory = false
        XCTAssertTrue(review(scan).isEmpty)
        for name in ["build.gradle", "pubspec.yaml", "build.zig", "main.tf", "game.uproject"] {
            var fake = fixture(marker: name); fake.nodes[2].isDirectory = true
            XCTAssertTrue(review(fake).isEmpty, name)
            fake.nodes[2].isDirectory = false; fake.nodes[2].isSymlink = true
            XCTAssertTrue(review(fake).isEmpty, name)
        }
        XCTAssertTrue(review(fixture(marker: "pubspec.yaml.backup")).isEmpty)
        var vendored = fixture(marker: "notes.txt"); vendored.nodes[4].name = "package.json"
        XCTAssertTrue(review(vendored).isEmpty)
    }

    func testNearestProjectOwnsExistingRootsWithoutDuplicatingBytes() {
        let scan = fixture(extra: [node(5, 1, "inner"), node(6, 5, "build.zig", directory: false),
                                  node(7, 5, "node_modules"), node(8, 7, "package.json", directory: false)])
        let records = review(scan)
        XCTAssertEqual(Set(records.map(\.id)), [1, 5])
        XCTAssertEqual(records.first { $0.id == 1 }?.project.findingIDs, [3])
        XCTAssertEqual(records.first { $0.id == 5 }?.project.findingIDs, [7])
        XCTAssertEqual(records.reduce(0) { $0 + $1.candidateBytes }, 200)
        var git = fixture(); git.nodes += [node(5, 1, ".git"), node(6, 5, "objects", directory: false)]
        let result = review(git, probes: [1: proof()])
        XCTAssertEqual(result[0].project.findingIDs, [3])
        XCTAssertEqual(ProjectPurgeReview.stageableSelection([1, 3, 5, 6], in: result), [3])
    }

    func testSymlinksMalformedTreesAndAgeSortingFailClosed() {
        let scan = fixture(extra: [node(5, 3, "link", directory: false, symlink: true)])
        XCTAssertTrue(review(scan, probes: [1: proof()])[0].artifacts[0].protections.contains(.symlink))
        var malformed = fixture(); malformed.nodes[1].parent = 1
        XCTAssertTrue(ProjectPurgeReview.build(scan: malformed, report: DeveloperReport(findings: [], projects: []), now: now).isEmpty)
        let sortedScan = fixture(extra: [node(5, 0, "older", modified: old.addingTimeInterval(-86400)),
                                        node(6, 5, "pubspec.yaml", directory: false, modified: old.addingTimeInterval(-86400))])
        let records = review(sortedScan)
        XCTAssertEqual(ProjectPurgeReview.sorted(records, by: .size).first?.id, 1)
        XCTAssertEqual(ProjectPurgeReview.sorted(records, by: .age).first?.id, 5)
        var unknown = sortedScan; unknown.nodes[6].modified = .distantPast
        XCTAssertEqual(ProjectPurgeReview.sorted(review(unknown), by: .age).last?.id, 5)
    }

    func testCancellableLinearAggregationOnLargeDeepFixture() throws {
        var scan = fixture()
        let depth = 12_000
        for offset in 0..<depth {
            let id = scan.nodes.count
            scan.nodes.append(node(id, offset == 0 ? 3 : id - 1, "level"))
        }
        let leaf = scan.nodes.count
        let recent = now.addingTimeInterval(-86400)
        scan.nodes.append(node(leaf, leaf - 1, "deployment-keypair.json", directory: false, modified: recent))
        for _ in 0..<12_000 {
            scan.nodes.append(node(scan.nodes.count, 1, "source.swift", directory: false))
        }
        let report = DeveloperReport.build(scan: scan, groups: DeveloperInsights.analyze(scan))
        var checkpoints = 0
        let records = ProjectPurgeReview.build(scan: scan, report: report,
            probes: [1: proof(tracked: [leaf])], now: now, cancellationCheck: { checkpoints += 1 })
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].newestModified, recent)
        XCTAssertTrue(records[0].artifacts[0].protections.contains(.deploymentKeypair))
        XCTAssertTrue(records[0].artifacts[0].protections.contains(.trackedFile))
        XCTAssertTrue(records[0].protections.contains(.recentModification))
        // Checkpoint count is deterministic and proportional to scan passes,
        // plus the two sparse deep evidence walks, rather than nodes * depth.
        XCTAssertGreaterThan(checkpoints, 100)
        XCTAssertLessThan(checkpoints, 1_000)
        let reversePassCutoff = 3 * ((scan.nodes.count + 255) / 256) + 8
        for cutoff in [1, reversePassCutoff] {
            var calls = 0
            XCTAssertThrowsError(try ProjectPurgeReview.build(scan: scan, report: report, now: now, cancellationCheck: {
                calls += 1
                if calls == cutoff { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(calls, cutoff)
        }
        var sparseCalls = 0
        // Four linear passes have completed; this cutoff is inside the first
        // deep injected-evidence walk, which must also respond to cancellation.
        let sparseCutoff = 4 * ((scan.nodes.count + 255) / 256) + 12
        XCTAssertThrowsError(try ProjectPurgeReview.build(scan: scan, report: report,
            probes: [1: proof(tracked: [leaf])], now: now, cancellationCheck: {
                sparseCalls += 1
                if sparseCalls == sparseCutoff { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(sparseCalls, sparseCutoff)
        scan.nodes[leaf].modified = .distantPast
        let unknown = review(scan, probes: [1: proof()])
        XCTAssertNil(unknown[0].newestModified)
        XCTAssertTrue(unknown[0].protections.contains(.unknownModification))
        XCTAssertTrue(unknown[0].artifacts[0].protections.contains(.deploymentKeypair))
    }

    func testUserReviewedPlanOnlySatisfiesRecoveryGate() {
        func planProbe(git: ProjectPurgeGitEvidence = .verified(trackedNodeIDs: [], checkoutRootIDs: []),
                       text: String = "  Restore using my reviewed source and toolchain plan.\n") -> ProjectPurgeProbe {
            ProjectPurgeProbe(git: git, recoveryPlans: [3: text])
        }
        let records = review(fixture(), probes: [1: planProbe()])
        XCTAssertEqual(records[0].stageableArtifactIDs, [3])
        XCTAssertNil(records[0].artifacts[0].rebuildabilityEvidence)
        XCTAssertEqual(records[0].artifacts[0].userReviewedRecoveryPlan, "Restore using my reviewed source and toolchain plan.")
        XCTAssertTrue(ProjectPurgeReview.stageableSelection([], in: records).isEmpty)
        let blank = review(fixture(), probes: [1: planProbe(text: " \n\t ")])
        XCTAssertTrue(blank[0].artifacts[0].protections.contains(.unprovenRebuildability))
        XCTAssertNil(blank[0].artifacts[0].userReviewedRecoveryPlan)
        let protectedScans: [(ScanResult, ProjectPurgeProtection)] = [
            (fixture(extra: [node(5, 3, "server.pem", directory: false)]), .deploymentKeypair),
            (fixture(extra: [node(5, 3, ".git", directory: false)]), .nestedCheckout),
            (fixture(extra: [node(5, 3, "link", directory: false, symlink: true)]), .symlink),
            (fixture(extra: [node(5, 1, "source", directory: false, modified: now)]), .recentModification),
            (fixture(extra: [node(5, 1, "source", directory: false, modified: .distantPast)]), .unknownModification)
        ]
        for (scan, reason) in protectedScans {
            let artifact = review(scan, probes: [1: planProbe()])[0].artifacts[0]
            XCTAssertTrue(artifact.protections.contains(reason))
            XCTAssertFalse(artifact.canStage)
        }
        for (git, reason): (ProjectPurgeGitEvidence, ProjectPurgeProtection) in [
            (.unavailable, .unverifiedGit),
            (.verified(trackedNodeIDs: [4], checkoutRootIDs: []), .trackedFile),
            (.verified(trackedNodeIDs: [], checkoutRootIDs: [3]), .workspaceRoot)
        ] {
            let artifact = review(fixture(), probes: [1: planProbe(git: git)])[0].artifacts[0]
            XCTAssertTrue(artifact.protections.contains(reason))
            XCTAssertFalse(artifact.canStage)
        }
    }
}
