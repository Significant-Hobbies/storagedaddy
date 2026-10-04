import Foundation
import Testing
@testable import DiskCore

struct DuplicateSurvivorProtectionTests {
    private var scan: ScanResult {
        ScanResult(rootPath: "/tmp/duplicate-protection-fixture", nodes: [
            DiskNode(id: 0, parent: nil, name: "Fixture", isDirectory: true, children: [1, 2]),
            DiskNode(id: 1, parent: 0, name: "kept.bin", isDirectory: false),
            DiskNode(id: 2, parent: 0, name: "folder", isDirectory: true, children: [3]),
            DiskNode(id: 3, parent: 2, name: "copy.bin", isDirectory: false)
        ])
    }
    @Test func directAndAncestorCoverageCannotRemovePromisedSurvivors() throws {
        let selection = DuplicateSurvivorSelection(members: [1, 3], kept: [1])
        try DuplicateSurvivorProtection.validateCoverage(scan: scan, selections: [selection], staged: [2])
        #expect(throws: NSError.self) { try DuplicateSurvivorProtection.validateCoverage(scan: scan, selections: [selection], staged: [1, 3]) }
        #expect(throws: NSError.self) { try DuplicateSurvivorProtection.validateCoverage(scan: scan, selections: [selection], staged: [0]) }
        #expect(throws: NSError.self) { try DuplicateSurvivorProtection.validateCoverage(scan: scan,
            selections: [.init(members: [1, 3], kept: [])], staged: [3]) }
    }
    @Test func finalCheckRevalidatesTheActualSurvivorAndPropagatesMissingIdentity() throws {
        let selection = DuplicateSurvivorSelection(members: [1, 3], kept: [1])
        var verified: [Int] = []
        try DuplicateSurvivorProtection.validateSurvivors(scan: scan, selections: [selection], staged: [3]) { _, node, _ in verified.append(node.id) }
        #expect(verified == [1])
        #expect(throws: NSError.self) {
            try DuplicateSurvivorProtection.validateSurvivors(scan: scan, selections: [selection], staged: [3]) { _, _, _ in
                throw NSError(domain: "FixtureMissingSurvivor", code: 1)
            }
        }
    }
}
