import Foundation
import XCTest
@testable import DiskCore

final class VolumeIORatesTests: XCTestCase {
    typealias M = StorageDashboardMetrics
    private let boot = Date(timeIntervalSince1970: 123)
    private func sample(_ time: Double = 10, bsd: String = "disk3s5", id: UInt64 = 42,
                        read: UInt64? = 100, write: UInt64? = 200, boot: Date? = nil) -> M.IOSample {
        M.IOSample(uptime: time, bootTime: boot ?? self.boot, drivers: [], volumes: [
            M.VolumeCounter(bsdName: bsd, registryID: id, readBytes: read, writtenBytes: write)
        ])
    }

    func testPseudoFilesystemInodeSentinelsAreUnavailable() {
        XCTAssertNil(M.inodes(total: UInt64(Int64.max), free: UInt64(Int64.max)))
        XCTAssertNil(M.inodes(total: .max, free: .max))
    }

    func testVolumeCountersWorkWithoutPhysicalDriverCounters() {
        let result = M.ioRates(previous: sample(), current: sample(12, read: 300, write: 200))
        XCTAssertEqual(result.read, .unavailable(.missingCounters))
        XCTAssertEqual(result.volumes.first?.bsdName, "disk3s5")
        XCTAssertEqual(result.volumes.first?.read, .measured(100))
        XCTAssertEqual(result.volumes.first?.write, .measured(0))
    }

    func testSnapshotNamesAndHotplugAreNeverGuessed() {
        XCTAssertEqual(M.volumeRates(previous: sample(), current: sample(12, bsd: "disk3s5s1")).first?.read, .unavailable(.identityChanged))
        XCTAssertEqual(M.volumeRates(previous: sample(), current: sample(12, id: 43)).first?.read, .unavailable(.identityChanged))
        XCTAssertEqual(M.volumeRates(previous: sample(), current: sample(12, boot: Date(timeIntervalSince1970: 124))).first?.read, .unavailable(.identityChanged))
    }

    func testMissingAndResetChannelsRemainIndependent() {
        let rates = M.volumeRates(previous: sample(), current: sample(12, read: nil, write: 199))[0]
        XCTAssertEqual(rates.read, .unavailable(.missingCounters))
        XCTAssertEqual(rates.write, .unavailable(.counterReset))
        XCTAssertEqual(M.volumeRates(previous: nil, current: sample())[0].read, .unavailable(.waitingForSample))
        XCTAssertEqual(M.volumeRates(previous: sample(), current: sample(10))[0].read, .unavailable(.invalidDuration))
        XCTAssertEqual(M.volumeRates(previous: sample(read: .max - 2), current: sample(12, read: .max))[0].read, .measured(1))
    }

    func testDuplicateIdentitiesFailClosed() {
        let first = sample()
        let repeated = M.IOSample(uptime: 12, bootTime: boot, drivers: [], volumes: first.volumes + first.volumes)
        XCTAssertTrue(M.volumeRates(previous: first, current: repeated).allSatisfy { $0.read == .unavailable(.identityChanged) })
    }
}
