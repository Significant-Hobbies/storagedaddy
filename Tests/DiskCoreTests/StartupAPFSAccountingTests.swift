import Foundation
import XCTest
@testable import DiskCore

final class StartupAPFSAccountingTests: XCTestCase {
    func testReadsActualStartupPoolWithoutFolderEnumeration() throws {
        guard let startup = SystemInventory.mountedVolumes().first(where: \.isStartupData), startup.fsType == "apfs" else {
            throw XCTSkip("No startup APFS Data volume on this test host")
        }
        let value = try XCTUnwrap(StartupAPFSAccounting.collect(startup: startup))
        XCTAssertGreaterThan(value.total, 0)
        XCTAssertGreaterThanOrEqual(value.available, 0)
        XCTAssertEqual(value.dataDevice, startup.bsdName)
        XCTAssertTrue(value.otherVolumes.contains { $0.roles.contains("System") })
    }

    private func member(_ device: String, _ name: String, _ bytes: Int64, _ role: String) -> [String: Any] {
        ["DeviceIdentifier": device, "Name": name, "CapacityInUse": bytes, "Roles": [role]]
    }
    private func payload(free: Int64 = 147, members: [[String: Any]]? = nil) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Containers": [
            ["ContainerReference": "disk9", "CapacityCeiling": 100, "CapacityFree": 0, "Volumes": [member("disk9s1", "Unrelated", 100, "Data")]],
            ["ContainerReference": "disk3", "CapacityCeiling": 1_000, "CapacityFree": free,
             "Volumes": members ?? [member("disk3s5", "Data", 800, "Data"), member("disk3s1", "System", 30, "System"), member("disk3s6", "VM", 20, "VM")]],
        ]], format: .xml, options: 0)
    }

    func testAccountsForPoolOnceIncludingUnmountedSystemVolumes() throws {
        let value = try XCTUnwrap(StartupAPFSAccounting.parse(payload(), container: "disk3", dataDevice: "disk3s5"))
        XCTAssertEqual(value.total, 1_000)
        XCTAssertEqual(value.available, 147)
        XCTAssertEqual(value.used, 853)
        XCTAssertEqual(value.dataBytes, 800)
        XCTAssertEqual(value.otherVolumes.map(\.name), ["System", "VM"])
        XCTAssertEqual(value.poolAdjustment, 3)
        XCTAssertEqual(value.dataBytes + value.otherVolumes.reduce(0) { $0 + $1.bytes } + value.poolAdjustment, value.used)
    }

    func testRetainsNegativePoolAdjustmentRatherThanInventingMetadataBytes() throws {
        let value = try XCTUnwrap(StartupAPFSAccounting.parse(payload(free: 300), container: "disk3", dataDevice: "disk3s5"))
        XCTAssertEqual(value.poolAdjustment, -150)
    }

    func testRejectsMissingDataVolumeAndWrongContainer() throws {
        XCTAssertNil(StartupAPFSAccounting.parse(try payload(), container: "disk7", dataDevice: "disk3s5"))
        XCTAssertNil(StartupAPFSAccounting.parse(try payload(), container: "disk3", dataDevice: "disk3s4"))
        XCTAssertNil(StartupAPFSAccounting.parse(try payload(members: [member("disk3s5", "Other", 800, "System")]), container: "disk3", dataDevice: "disk3s5"))
    }

    func testRejectsPartialOrInvalidVolumeMeasurements() throws {
        for members in [
            [member("disk3s5", "Data", -1, "Data")],
            [member("disk3s5", "Data", 800, "Data"), member("disk3s5", "Duplicate", 800, "Data")],
            [member("disk3s5", "Data", Int64.max, "Data"), member("disk3s1", "System", 1, "System")],
            [["DeviceIdentifier": "disk3s5", "Name": "Data", "Roles": ["Data"]]],
        ] {
            XCTAssertNil(StartupAPFSAccounting.parse(try payload(members: members), container: "disk3", dataDevice: "disk3s5"))
        }
        XCTAssertNil(StartupAPFSAccounting.parse(try payload(free: 1_001), container: "disk3", dataDevice: "disk3s5"))
        XCTAssertNil(StartupAPFSAccounting.parse(Data("invalid".utf8), container: "disk3", dataDevice: "disk3s5"))
    }
}
