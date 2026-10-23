import Darwin
import XCTest
@testable import DiskCore

final class RuntimeSamplingTests: XCTestCase {
    func testCPUUsesIntervalCounterAndOneCoreScale() {
        XCTAssertEqual(RuntimeRates.cpu(previous: 7_000_000_000, current: 8_000_000_000, elapsed: 2), 50)
        XCTAssertEqual(RuntimeRates.cpu(previous: 0, current: 4_000_000_000, elapsed: 2), 200)
        XCTAssertEqual(RuntimeRates.cpu(previous: 42, current: 42, elapsed: 2), 0)
    }
    func testCPUUnknownIdentityResetAndStaleSamplesStayUnknown() {
        XCTAssertNil(RuntimeRates.cpu(previous: nil, current: 1_000, elapsed: 2))
        XCTAssertNil(RuntimeRates.cpu(previous: 3_000, current: 1_000, elapsed: 2))
        XCTAssertNil(RuntimeRates.cpu(previous: 1_000, current: nil, elapsed: 2))
        XCTAssertNil(RuntimeRates.cpu(previous: 1_000, current: 3_000, elapsed: 2, sameIdentity: false))
        XCTAssertNil(RuntimeRates.cpu(previous: 1_000, current: 3_000, elapsed: .nan))
        XCTAssertNil(RuntimeRates.cpu(previous: 1_000, current: 3_000, elapsed: 60))
    }
    func testHostCPUIsOverallRatherThanPerCore() {
        XCTAssertEqual(RuntimeRates.hostCPU(previousBusy: 20, previousTotal: 100, busy: 70, total: 200), 50)
        XCTAssertNil(RuntimeRates.hostCPU(previousBusy: 100, previousTotal: 100, busy: 90, total: 200))
        XCTAssertNil(RuntimeRates.hostCPU(previousBusy: 20, previousTotal: 100, busy: 70, total: 100))
        XCTAssertNil(RuntimeRates.hostCPU(previousBusy: 0, previousTotal: 0, busy: 200, total: 100))
    }
    func testPIDReuseChangesIdentity() {
        XCTAssertNotEqual(RuntimeProcessIdentity(pid: 123, started: 100), RuntimeProcessIdentity(pid: 123, started: 101))
    }
    @MainActor
    func testLiveSamplerIncludesObserverWithoutInventingInitialCPU() async {
        let sampler = RuntimeSampler()
        let sample = await sampler.sample()
        let observer = sample.processes.first { $0.id.pid == getpid() }
        XCTAssertNotNil(observer)
        XCTAssertNil(observer?.cpuPercent)
        XCTAssertGreaterThan(observer?.residentBytes ?? 0, 0)
        XCTAssertTrue(sample.processes.contains { $0.cpuPercent == nil })
        XCTAssertGreaterThan(sample.memory?.physicalBytes ?? 0, 0)
        try? await Task.sleep(for: .milliseconds(150))
        let second = await sampler.sample()
        XCTAssertNotNil(second.processes.first { $0.id == observer?.id }?.cpuPercent)
        XCTAssertNotNil(second.cpuPercent)
    }
}
