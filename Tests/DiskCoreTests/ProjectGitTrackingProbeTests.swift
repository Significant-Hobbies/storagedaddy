import Foundation
import Testing
@testable import DiskCore

struct ProjectGitTrackingProbeTests {
    private var scan: ScanResult {
        ScanResult(rootPath: "/tmp/project-index-fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "workspace", isDirectory: true, children: [1]),
            DiskNode(id: 1, parent: 0, name: "dist[prod]", isDirectory: true, children: [2]),
            DiskNode(id: 2, parent: 1, name: "file\nname.js", isDirectory: false)
        ])
    }
    @Test func matchesNulDelimitedIndexWithoutReadingBodies() throws {
        var commands: [[String]] = []
        let evidence = try ProjectGitTrackingProbe.collect(scan: scan, projectID: 0, artifactIDs: [1]) { _, args in
            commands.append(args)
            return args.first == "rev-parse" ? "true\n" : "dist[prod]/file\nname.js\0"
        }
        if case let .verified(ids, roots) = evidence { #expect(ids == [2]); #expect(roots == [0]) }
        else { Issue.record("Expected verified tracked node") }
        #expect(commands.last == ["ls-files", "--cached", "-z", "--", "dist[prod]"])
    }
    @Test func missingTruncatedForeignAndFailedIndexStayBlocked() throws {
        for output in ["dist[prod]/missing.js\0", "dist[prod]/file\nname.js", "../foreign\0", "other/file.js\0"] {
            let evidence = try ProjectGitTrackingProbe.collect(scan: scan, projectID: 0, artifactIDs: [1]) { _, args in
                args.first == "rev-parse" ? "true\n" : output
            }
            guard case .failed = evidence else { Issue.record("Invalid index must fail closed"); continue }
        }
        let unknown = try ProjectGitTrackingProbe.collect(scan: scan, projectID: 0, artifactIDs: [1]) { _, _ in nil }
        guard case .unavailable = unknown else { Issue.record("Missing repository must stay unknown"); return }
    }
}
