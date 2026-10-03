import Foundation
import Testing
@testable import DiskCore

private let ageNow = Date(timeIntervalSince1970: 1_754_006_400) // 2025-08-01 UTC
private func ageFile(_ id: Int, days: Double, allocated: Int64, logical: Int64? = nil) -> DiskNode {
    DiskNode(id: id, parent: 0, name: "fixture", isDirectory: false,
             logicalBytes: logical ?? allocated, allocatedBytes: allocated,
             modified: ageNow.addingTimeInterval(-days * 86400))
}
private func ageScan(_ files: [DiskNode]) -> ScanResult {
    ScanResult(rootPath: "/synthetic-only", nodes: [DiskNode(id: 0, parent: nil, name: "root", isDirectory: true, allocatedBytes: 999_999)] + files)
}
private var utcCalendar: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
}

@Test func agePercentilesWeightBytesAndToggleAllocation() throws {
    let scan = ageScan([ageFile(1, days: 1, allocated: 90, logical: 1), ageFile(2, days: 100, allocated: 10, logical: 99), ageFile(3, days: 500, allocated: 0)])
    let a = try FileAgeHistogram.calculate(in: scan, now: ageNow, calendar: utcCalendar)
    #expect(a.percentiles?.p50 == 86400)
    #expect(a.percentiles?.p90 == 86400)
    #expect(a.percentiles?.p95 == Double(100 * 86400))
    let l = try FileAgeHistogram.calculate(in: scan, allocated: false, now: ageNow, calendar: utcCalendar)
    #expect(l.percentiles?.p50 == Double(100 * 86400))
    #expect(a.totalBytes == 100)
    #expect(a.totalFiles == 3)
}

@Test func ageEmptyZeroUnknownAndFuture() throws {
    let empty = try FileAgeHistogram.calculate(in: ScanResult(rootPath: "/fixture", nodes: []), now: ageNow)
    #expect(empty.percentiles == nil)
    #expect(empty.totalFiles == 0)
    var unknown = ageFile(2, days: 1, allocated: 30); unknown.modified = .distantPast
    let a = try FileAgeHistogram.calculate(in: ageScan([ageFile(1, days: 1, allocated: 0), unknown, ageFile(3, days: -1, allocated: 40)]), now: ageNow)
    #expect(a.percentiles == nil)
    #expect(a.buckets[25].bytes == 30)
    #expect(a.buckets[26].bytes == 40)
    #expect(a.totalBytes == 70)
    #expect(a.buckets.reduce(0) { $0 + $1.count } == 3)
}

@Test func ageCalendarBoundariesAndCardinality() throws {
    let now = utcCalendar.date(from: DateComponents(year: 2025, month: 4, day: 1))!
    let atBoundary = DiskNode(id: 1, parent: 0, name: "boundary", isDirectory: false, allocatedBytes: 7, modified: now)
    var before = atBoundary; before.id = 2; before.modified = now.addingTimeInterval(-1)
    for granularity in [FileAgeGranularity.monthly, .quarterly, .yearly] {
        let result = try FileAgeHistogram.calculate(in: ageScan([atBoundary, before]), granularity: granularity, now: now, calendar: utcCalendar)
        #expect(result.buckets.count == 27)
        #expect(result.buckets[0].count == (granularity == .yearly ? 2 : 1))
        #expect(result.buckets[1].count == (granularity == .yearly ? 0 : 1))
    }
}

@Test func ageCancellationDuringPercentilePassDoesNotPublishPartialState() throws {
    var checks = 0
    #expect(throws: CancellationError.self) {
        _ = try FileAgeHistogram.calculate(in: ageScan([ageFile(1, days: 1, allocated: 1)]), now: ageNow, checkCancellation: {
            checks += 1
            if checks == 5 { throw CancellationError() }
        })
    }
    #expect(checks == 5)
}

@Test func ageFocusedScopeAndOverflow() throws {
    var included = ageFile(2, days: 5, allocated: 12); included.parent = 1
    let scan = ScanResult(rootPath: "/fixture", nodes: [DiskNode(id: 0, parent: nil, name: "root", isDirectory: true), DiskNode(id: 1, parent: 0, name: "folder", isDirectory: true), included, ageFile(3, days: 100, allocated: 99)])
    let result = try FileAgeHistogram.calculate(in: scan, focus: 1, now: ageNow)
    #expect(result.totalBytes == 12)
    #expect(result.percentiles?.p95 == Double(5 * 86400))
    #expect(throws: FileAgeHistogram.CalculationError.self) {
        _ = try FileAgeHistogram.calculate(in: ageScan([ageFile(1, days: 1, allocated: .max), ageFile(2, days: 2, allocated: 1)]), now: ageNow)
    }
}

@Test func ageRadixMatchesIndependentWeightedOrder() throws {
    let files = (1...257).map { id in ageFile(id, days: Double((id * 73) % 257) + 0.125, allocated: Int64((id * 19) % 41)) }
    let result = try FileAgeHistogram.calculate(in: ageScan(files), now: ageNow)
    let sorted = files.sorted { $0.modified > $1.modified }
    let total = files.reduce(Int64(0)) { $0 + $1.allocatedBytes }
    let expected = [50, 90, 95].map { p in
        let rank = (total * Int64(p) + 99) / 100
        var accumulated: Int64 = 0
        for file in sorted {
            accumulated += file.allocatedBytes
            if accumulated >= rank { return ageNow.timeIntervalSince(file.modified) }
        }
        return -1.0
    }
    let actual = try #require(result.percentiles)
    #expect([actual.p50, actual.p90, actual.p95] == expected)
}

@Test func ageMillionNodeFixtureKeepsFixedResultCardinality() throws {
    let nodes = (0..<1_000_000).map { id in ageFile(id, days: Double(id % 3650), allocated: 1) }
    let result = try FileAgeHistogram.calculate(in: ScanResult(rootPath: "/synthetic", nodes: nodes), now: ageNow, checkCancellation: {})
    #expect(result.buckets.count == 27)
    #expect(result.totalFiles == 1_000_000)
    #expect(result.totalBytes == 1_000_000)
    #expect(result.buckets.reduce(Int64(0)) { $0 + $1.bytes } == 1_000_000)
}
