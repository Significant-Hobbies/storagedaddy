import Foundation

public enum FileAgeGranularity: String, CaseIterable, Sendable, Identifiable {
    case monthly = "Monthly", quarterly = "Quarterly", yearly = "Yearly"
    public var id: String { rawValue }
    var months: Int { switch self { case .monthly: 1; case .quarterly: 3; case .yearly: 12 } }
}

public struct FileAgeBucket: Sendable, Identifiable {
    public let id: Int
    /// Half-open modification date interval; nil for special buckets.
    public let start: Date?
    public let end: Date?
    public var bytes: Int64 = 0
    public var count: Int = 0
    public var largestID: Int?
    var largestBytes: Int64 = -1
}

public struct FileAgePercentiles: Sendable {
    /// Exact weighted nearest-rank ages in seconds, among positive-byte files
    /// with known, non-future dates. Zero-byte files do not affect ranks.
    public let p50: TimeInterval
    public let p90: TimeInterval
    public let p95: TimeInterval
}

public struct FileAgeHistogram: Sendable {
    public let granularity: FileAgeGranularity
    public let now: Date
    public let calendar: Calendar
    public let allocated: Bool
    public let buckets: [FileAgeBucket]
    public let totalBytes: Int64
    public let totalFiles: Int
    public let datedBytes: Int64
    public let percentiles: FileAgePercentiles?

    public enum CalculationError: Error { case invalidScope, invalidCalendar, byteOverflow }

    /// Metadata only. At most 27 buckets and 3 x 256 radix counters, regardless
    /// of scan cardinality. Eight additional passes select exact percentiles;
    /// no per-file age array, sorting, paths, or filesystem reads are used.
    /// Scope uses existing node indices/parents, with no descendant set/stack.
    /// Parent chains must describe a tree; malformed cycles are bounded.
    public static func calculate(in scan: ScanResult, focus: Int = 0,
                                 granularity: FileAgeGranularity = .monthly,
                                 allocated: Bool = true, search: String = "", now: Date,
                                 calendar: Calendar = Calendar(identifier: .gregorian),
                                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Self {
        try checkCancellation()
        guard (scan.nodes.isEmpty && focus == 0) || scan.nodes.indices.contains(focus) else { throw CalculationError.invalidScope }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let year = calendar.dateInterval(of: .year, for: now)?.start else { throw CalculationError.invalidCalendar }
        let month = calendar.component(.month, from: now)
        let offset = granularity == .yearly ? 0 : ((month - 1) / granularity.months) * granularity.months
        guard let current = calendar.date(byAdding: .month, value: offset, to: year) else { throw CalculationError.invalidCalendar }
        var buckets: [FileAgeBucket] = []
        for i in 0..<24 {
            guard let start = calendar.date(byAdding: .month, value: -i * granularity.months, to: current),
                  let end = calendar.date(byAdding: .month, value: (1-i) * granularity.months, to: current) else { throw CalculationError.invalidCalendar }
            buckets.append(FileAgeBucket(id: i, start: start, end: end))
        }
        buckets += [FileAgeBucket(id: 24, start: nil, end: nil), FileAgeBucket(id: 25, start: nil, end: nil), FileAgeBucket(id: 26, start: nil, end: nil)]
        func scoped(_ index: Int) throws -> Bool {
            if focus == 0 { return true }
            var cursor: Int? = index
            var remaining = scan.nodes.count
            while let id = cursor, scan.nodes.indices.contains(id), remaining > 0 {
                try checkCancellation()
                if id == focus { return true }
                cursor = scan.nodes[id].parent
                remaining -= 1
            }
            return false
        }
        func ageKey(_ node: DiskNode) -> UInt64? {
            let date = node.modified
            guard date != .distantPast, date.timeIntervalSinceReferenceDate.isFinite, date <= now else { return nil }
            let age = max(0, now.timeIntervalSince(date))
            return age.isFinite ? age.bitPattern : nil
        }
        func add(_ value: Int64, to total: inout Int64) throws {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { throw CalculationError.byteOverflow }
            total = sum.partialValue
        }
        var totalBytes: Int64 = 0, datedBytes: Int64 = 0, totalFiles = 0
        for index in scan.nodes.indices {
            try checkCancellation()
            let node = scan.nodes[index]
            guard !node.isDirectory, search.isEmpty || node.name.localizedCaseInsensitiveContains(search), try scoped(index) else { continue }
            let bytes = max(0, allocated ? node.allocatedBytes : node.logicalBytes)
            let key = ageKey(node)
            let bucket: Int
            if node.modified == .distantPast || !node.modified.timeIntervalSinceReferenceDate.isFinite || (key == nil && node.modified <= now) { bucket = 25 }
            else if node.modified > now { bucket = 26 }
            else { bucket = buckets.prefix(24).firstIndex { node.modified >= $0.start! && node.modified < $0.end! } ?? 24 }
            try add(bytes, to: &totalBytes)
            try add(bytes, to: &buckets[bucket].bytes)
            buckets[bucket].count += 1
            totalFiles += 1
            if bytes > buckets[bucket].largestBytes {
                buckets[bucket].largestBytes = bytes
                buckets[bucket].largestID = node.id
            }
            if key != nil { try add(bytes, to: &datedBytes) }
        }
        var percentiles: FileAgePercentiles?
        if datedBytes > 0 {
            // Integer ceiling avoids rounding ranks above 2^53.
            let ranks = [50, 90, 95].map { p in (datedBytes / 100) * Int64(p) + ((datedBytes % 100) * Int64(p) + 99) / 100 }
            var remaining = ranks
            var prefixes = [UInt64](repeating: 0, count: 3)
            for pass in 0..<8 {
                var counts = [[Int64]](repeating: [Int64](repeating: 0, count: 256), count: 3)
                let shift = (7-pass) * 8
                let mask: UInt64 = pass == 0 ? 0 : UInt64.max << (64-pass*8)
                for index in scan.nodes.indices {
                    try checkCancellation()
                    let node = scan.nodes[index]
                    guard !node.isDirectory, search.isEmpty || node.name.localizedCaseInsensitiveContains(search), try scoped(index), let key = ageKey(node) else { continue }
                    let bytes = max(0, allocated ? node.allocatedBytes : node.logicalBytes)
                    let digit = Int((key >> shift) & 255)
                    for p in 0..<3 where key & mask == prefixes[p] { counts[p][digit] += bytes }
                }
                for p in 0..<3 {
                    for digit in 0..<256 {
                        if remaining[p] > counts[p][digit] { remaining[p] -= counts[p][digit] }
                        else { prefixes[p] |= UInt64(digit) << shift; break }
                    }
                }
            }
            percentiles = FileAgePercentiles(p50: Double(bitPattern: prefixes[0]), p90: Double(bitPattern: prefixes[1]), p95: Double(bitPattern: prefixes[2]))
        }
        try checkCancellation()
        return Self(granularity: granularity, now: now, calendar: calendar, allocated: allocated, buckets: buckets, totalBytes: totalBytes, totalFiles: totalFiles, datedBytes: datedBytes, percentiles: percentiles)
    }
}
