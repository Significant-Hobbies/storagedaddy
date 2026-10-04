import XCTest
@testable import DiskCore

final class StorageDashboardMetricsTests: XCTestCase {
    private typealias Metrics = StorageDashboardMetrics
    private func sample(_ time: Double = 10, boot: Date? = Date(timeIntervalSince1970: 1),
                        id: UInt64 = 42, read: UInt64? = 100, write: UInt64? = 200) -> Metrics.IOSample {
        Metrics.IOSample(uptime: time, bootTime: boot, drivers: [
            Metrics.DriverCounter(registryID: id, readBytes: read, writtenBytes: write)
        ])
    }

    func testInodeBoundsAndUnavailable() {
        XCTAssertNil(Metrics.inodes(total: nil, free: 1))
        XCTAssertNil(Metrics.inodes(total: 0, free: 0))
        XCTAssertNil(Metrics.inodes(total: 100, free: nil))
        XCTAssertNil(Metrics.inodes(total: 100, free: 101))
        XCTAssertEqual(Metrics.inodes(total: 100, free: 0)?.used, 100)
        XCTAssertEqual(Metrics.inodes(total: 100, free: 100)?.usedRatio, 0)
        XCTAssertEqual(Metrics.inodes(total: .max, free: .max)?.used, 0)
        XCTAssertEqual(Metrics.inodes(total: 100, free: 25)?.usedRatio, 0.75)
    }

    func testTwoSamplesAndMeasuredZero() {
        XCTAssertEqual(Metrics.ioRates(previous: nil, current: sample()), .waiting)
        let rates = Metrics.ioRates(previous: sample(), current: sample(12, read: 300, write: 200))
        XCTAssertEqual(rates.read, .measured(100))
        XCTAssertEqual(rates.write, .measured(0))
        XCTAssertEqual(rates.interval, 2)
    }

    func testResetsAndMissingAreNotZero() {
        let reset = Metrics.ioRates(previous: sample(), current: sample(12, read: 99, write: 500))
        XCTAssertEqual(reset.read, .unavailable(.counterReset))
        XCTAssertEqual(reset.write, .measured(150))
        XCTAssertEqual(Metrics.ioRates(previous: sample(read: nil), current: sample(12)).read, .unavailable(.missingCounters))
        XCTAssertEqual(Metrics.ioRates(previous: sample(), current: sample(12, write: nil)).write, .unavailable(.missingCounters))
        XCTAssertEqual(Metrics.ioRates(previous: sample(boot: nil), current: sample(12)).read, .unavailable(.missingCounters))
        let empty = Metrics.IOSample(uptime: 12, bootTime: Date(timeIntervalSince1970: 1), drivers: [])
        XCTAssertEqual(Metrics.ioRates(previous: sample(), current: empty).read, .unavailable(.missingCounters))
    }

    func testIdentityAndTimeValidation() {
        XCTAssertEqual(Metrics.ioRates(previous: sample(), current: sample(12, id: 43)).read, .unavailable(.identityChanged))
        XCTAssertEqual(Metrics.ioRates(previous: sample(), current: sample(12, boot: Date(timeIntervalSince1970: 2))).read, .unavailable(.identityChanged))
        for time in [10.0, 9, .nan, .infinity] {
            XCTAssertEqual(Metrics.ioRates(previous: sample(), current: sample(time)).read, .unavailable(.invalidDuration))
        }
        let duplicates = Metrics.IOSample(uptime: 12, bootTime: sample().bootTime, drivers: sample().drivers + sample().drivers)
        XCTAssertEqual(Metrics.ioRates(previous: sample(), current: duplicates).read, .unavailable(.identityChanged))
        XCTAssertEqual(Metrics.ioRates(previous: sample(id: 0), current: sample(12, id: 0)).read, .unavailable(.identityChanged))
    }

    func testAggregateRequiresEveryDriverAndNeverClaimsVolumeAttribution() {
        let first = Metrics.IOSample(uptime: 10, bootTime: sample().bootTime, drivers: sample().drivers + sample(id: 43).drivers)
        let last = Metrics.IOSample(uptime: 12, bootTime: first.bootTime, drivers: sample(id: 43, read: 500).drivers + sample(read: 300).drivers)
        let rates = Metrics.ioRates(previous: first, current: last)
        XCTAssertEqual(rates.read, .measured(300))
        XCTAssertTrue(rates.attribution.contains("Aggregate"))
        XCTAssertTrue(rates.perVolumeUnavailableReason.contains("not assigned"))
        let missing = Metrics.IOSample(uptime: 12, bootTime: first.bootTime, drivers: sample(read: nil).drivers + sample(id: 43).drivers)
        XCTAssertEqual(Metrics.ioRates(previous: first, current: missing).read, .unavailable(.missingCounters))
    }

    func testLargeCountersPreserveSmallDelta() {
        XCTAssertEqual(Metrics.ioRates(previous: sample(read: .max - 2), current: sample(12, read: .max)).read, .measured(1))
    }

    func testScoreCoverageAndUnknownVersusMeasuredZero() {
        let unknown = Metrics.score(totalBytes: nil, freeBytes: nil, purgeableBytes: nil, nvmePercentUsed: nil, snapshotCount: nil)
        XCTAssertNil(unknown.earnedPoints)
        XCTAssertEqual(unknown.coverage, 0)
        let partial = Metrics.score(totalBytes: 100, freeBytes: 20, purgeableBytes: 0, nvmePercentUsed: nil, snapshotCount: nil)
        XCTAssertEqual(partial.earnedPoints, 50)
        XCTAssertEqual(partial.coverage, 0.5)
        XCTAssertFalse(partial.isComplete)
        XCTAssertNil(partial.components[2].points)
        let measured = Metrics.score(totalBytes: 100, freeBytes: 0, purgeableBytes: 0, nvmePercentUsed: 100, snapshotCount: 0)
        XCTAssertEqual(measured.components[0].points, 0)
        XCTAssertEqual(measured.components[2].points, 0)
        XCTAssertEqual(measured.components[3].points, 25)
        XCTAssertEqual(measured.coverage, 1)
        XCTAssertTrue(measured.isComplete)
        XCTAssertEqual(Metrics.score(totalBytes: 100, freeBytes: 20, purgeableBytes: 0, nvmePercentUsed: 0, snapshotCount: 0).earnedPoints, 100)
    }

    func testInvalidScoreInputsAndWearBeyondNominalEndurance() {
        let invalid = Metrics.score(totalBytes: 100, freeBytes: 101, purgeableBytes: -1, nvmePercentUsed: -1, snapshotCount: -1)
        XCTAssertNil(invalid.earnedPoints)
        XCTAssertNil(Metrics.score(totalBytes: 0, freeBytes: 0, purgeableBytes: 0, nvmePercentUsed: 256, snapshotCount: nil).earnedPoints)
        XCTAssertEqual(Metrics.score(totalBytes: nil, freeBytes: nil, purgeableBytes: nil, nvmePercentUsed: 255, snapshotCount: 10).earnedPoints, 12.5)
    }
}
