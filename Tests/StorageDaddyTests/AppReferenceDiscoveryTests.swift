import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

struct AppReferenceDiscoveryTests {
    @Test func traversalAndRetentionLimitsCannotProveAbsence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-app-reference-bounds-\(UUID().uuidString)")
        for name in ["One.app", "Two.app", "Three.app", "nested/deeper/Four.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let metadata: (URL) -> AppLeftoverInventory.Application? = { url in
            .init(bundleID: "com.fixture." + url.deletingPathExtension().lastPathComponent.lowercased(), names: [url.lastPathComponent])
        }
        for result in [try AppReferenceDiscovery.collect(roots: [root], maximumEntries: 1, metadata: metadata),
                       try AppReferenceDiscovery.collect(roots: [root], maximumApplications: 1, metadata: metadata),
                       try AppReferenceDiscovery.collect(roots: [root], maximumDepth: 1, metadata: metadata)] {
            #expect(result.completeness == .partial); #expect(!result.supportsAbsenceEvidence)
        }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("One.app"))
        let symbolic = try AppReferenceDiscovery.collect(roots: [alias], metadata: metadata)
        #expect(symbolic.completeness == .partial); #expect(!symbolic.supportsAbsenceEvidence)
    }
    @Test func referenceUsesOnlySuppliedFixtureRootsAndFailsClosedOnMissingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-app-reference-\(UUID().uuidString)")
        for name in ["Live.app", "Unknown.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let complete = try AppReferenceDiscovery.collect(roots: [root], now: now) { url in
            AppLeftoverInventory.Application(bundleID: "com.fixture." + url.deletingPathExtension().lastPathComponent.lowercased(),
                names: [url.deletingPathExtension().lastPathComponent])
        }
        #expect(complete.completeness == .complete); #expect(complete.supportsAbsenceEvidence)
        #expect(complete.applications.count == 2); #expect(complete.checkedAt == now)
        let partial = try AppReferenceDiscovery.collect(roots: [root], now: now) { url in
            url.lastPathComponent == "Unknown.app" ? nil : AppLeftoverInventory.Application(bundleID: "com.fixture.live", names: ["Live"])
        }
        #expect(partial.completeness == .partial); #expect(!partial.supportsAbsenceEvidence)
        let empty = try AppReferenceDiscovery.collect(roots: [root.appendingPathComponent("missing")], now: now)
        #expect(!empty.supportsAbsenceEvidence)
    }
}
