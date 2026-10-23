import Foundation
import XCTest
@testable import DiskCore

final class RuntimeProcessPresentationTests: XCTestCase {
    private func process(_ pid: Int32, started: UInt64 = 100, parent: Int32 = 1, name: String = "worker", path: String? = nil, cpu: Double? = 10, memory: UInt64? = 100) -> RuntimeProcess {
        RuntimeProcess(id: .init(pid: pid, started: started), parentPID: parent, uid: 501, name: name, executablePath: path, residentBytes: memory, cpuPercent: cpu)
    }

    func testCPUScaleKeepsCountersAndUnavailabilityHonest() {
        XCTAssertEqual(RuntimeCPUScale.oneCore.processPercent(200, logicalCoreCount: 8), 200)
        XCTAssertEqual(RuntimeCPUScale.wholeSystem.processPercent(200, logicalCoreCount: 8), 25)
        XCTAssertNil(RuntimeCPUScale.wholeSystem.processPercent(200, logicalCoreCount: 0))
        XCTAssertNil(RuntimeCPUScale.oneCore.processPercent(nil, logicalCoreCount: 8))
        XCTAssertNil(RuntimeCPUScale.oneCore.processPercent(.nan, logicalCoreCount: 8))
        XCTAssertNil(RuntimeCPUScale.oneCore.processPercent(-1, logicalCoreCount: 8))
        XCTAssertEqual(RuntimeCPUScale.oneCore.processPercent(0, logicalCoreCount: 8), 0)
    }

    func testParentGroupsDoNotMergeAllLaunchdChildrenAndKeepGrandchildren() throws {
        let terminal = process(20, name: "Terminal", cpu: 3, memory: 100)
        let shell = process(21, started: 110, parent: 20, cpu: 5, memory: 200)
        let worker = process(22, started: 120, parent: 21, cpu: 7, memory: 300)
        let editor = process(30, name: "Editor", cpu: 11, memory: 400)
        let groups = RuntimeProcessGroups.build([worker, editor, shell, terminal], grouping: .parentTree)
        XCTAssertEqual(groups.count, 2)
        let family = try XCTUnwrap(groups.first(where: { $0.representative.id.pid == 20 }))
        XCTAssertEqual(family.members.map(\.id.pid), [20, 21, 22])
        XCTAssertEqual(family.cpuPercent, 15)
        XCTAssertEqual(family.residentBytes, 600)
        XCTAssertEqual(family.name, "Terminal")
    }

    func testParentPIDReuseAndCyclesCannotJoinUnrelatedProcesses() throws {
        let oldChild = process(11, started: 10, parent: 10)
        let reusedParent = process(10, started: 20)
        XCTAssertEqual(RuntimeProcessGroups.build([oldChild, reusedParent], grouping: .parentTree).count, 2)
        let a = process(40, parent: 41), b = process(41, parent: 40), child = process(12, started: 120, parent: 40)
        let cycle = RuntimeProcessGroups.build([child, b, a], grouping: .parentTree)
        XCTAssertEqual(cycle.count, 1)
        XCTAssertEqual(cycle.first?.representative.id.pid, 40)
        XCTAssertEqual(cycle.first?.members.count, 3)
    }

    func testApplicationsUseOuterBundleAndKeepUnbundledToolsSeparate() throws {
        let app = process(1_000, name: "Browser", path: "/Applications/Browser.app/Contents/MacOS/Browser", cpu: 50, memory: 100)
        let helper = process(1_001, started: 120, parent: 1_000, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", cpu: 150, memory: 300)
        let shell = process(1_002, started: 130, parent: 1_000, path: "/bin/zsh", cpu: 5)
        let groups = RuntimeProcessGroups.build([helper, shell, app], grouping: .application)
        XCTAssertEqual(groups.count, 2)
        let browser = try XCTUnwrap(groups.first(where: { $0.name == "Browser" }))
        XCTAssertEqual(browser.representative.id, app.id)
        XCTAssertEqual(browser.members.count, 2)
        XCTAssertEqual(browser.cpuPercent, 200)
        XCTAssertEqual(browser.residentBytes, 400)
        XCTAssertTrue(groups.contains(where: { $0.members.count == 1 && $0.members[0].id == shell.id }))
    }

    func testPartialGroupMetricsRemainUnknownAndOverflowDoesNotWrap() {
        let parent = process(20, cpu: 2, memory: .max)
        let child = process(21, started: 120, parent: 20, cpu: nil, memory: 1)
        let group = RuntimeProcessGroups.build([parent, child], grouping: .parentTree).first
        XCTAssertNil(group?.cpuPercent)
        XCTAssertNil(group?.residentBytes)
    }

    func testHistorySeparatesPIDReuseAndPreservesMissingSlotsAndCoreCounts() throws {
        let first = process(30, started: 10, cpu: 200, memory: 500)
        let reused = process(30, started: 20, cpu: 80, memory: 800)
        var history = RuntimeProcessHistory(limit: 4)
        history.append(date: Date(timeIntervalSince1970: 1), logicalCoreCount: 8, processes: [first])
        history.append(date: Date(timeIntervalSince1970: 2), logicalCoreCount: 4, processes: [first])
        history.append(date: Date(timeIntervalSince1970: 3), logicalCoreCount: 4, processes: [])
        history.append(date: Date(timeIntervalSince1970: 4), logicalCoreCount: 4, processes: [reused])
        XCTAssertEqual(history.values(for: RuntimeProcessGroups.processID(first.id), metric: .cpu, scale: .wholeSystem), [25, 50, nil, nil])
        XCTAssertEqual(history.values(for: RuntimeProcessGroups.processID(reused.id), metric: .residentMemory), [nil, nil, nil, 800])
        history.append(date: Date(timeIntervalSince1970: 5), logicalCoreCount: 4, processes: [reused])
        XCTAssertEqual(history.frames.count, 4)
        XCTAssertEqual(history.frames.first?.date, Date(timeIntervalSince1970: 2))
        history.removeAll()
        XCTAssertTrue(history.frames.isEmpty)
    }

    func testGroupHistoryUsesMembershipOfEachHistoricalSample() throws {
        let path = "/Applications/Editor.app/Contents/MacOS/Editor"
        let parent = process(40, path: path, cpu: 10)
        let helper = process(41, started: 120, parent: 40, path: path, cpu: 20)
        var history = RuntimeProcessHistory()
        history.append(date: .distantPast, logicalCoreCount: 8, processes: [parent])
        history.append(date: .distantPast, logicalCoreCount: 8, processes: [parent, helper])
        history.append(date: .distantPast, logicalCoreCount: 8, processes: [parent])
        let group = try XCTUnwrap(RuntimeProcessGroups.build([parent], grouping: .application).first)
        XCTAssertEqual(history.values(for: group.id, metric: .cpu), [10, 30, 10])
    }

    func testTrendSegmentsDoNotBridgeUnknownSamplesAndKeepTimePosition() throws {
        let segments = RuntimeTrendSegments.make(values: [0, 50, nil, 100, .nan, 20], width: 100, height: 50, minimumCeiling: 100)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], [.init(x: 0, y: 50), .init(x: 20, y: 25)])
        XCTAssertEqual(segments[1], [.init(x: 60, y: 0)])
        XCTAssertEqual(segments[2], [.init(x: 100, y: 40)])
        XCTAssertTrue(RuntimeTrendSegments.make(values: [nil], width: 100, height: 50).isEmpty)
        XCTAssertTrue(RuntimeTrendSegments.make(values: [1], width: .nan, height: 50).isEmpty)
    }
}
