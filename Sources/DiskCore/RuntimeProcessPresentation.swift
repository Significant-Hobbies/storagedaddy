import Foundation

public enum RuntimeCPUScale: String, Codable, Sendable, CaseIterable, Identifiable {
    case oneCore = "One core", wholeSystem = "Whole system"
    public var id: String { rawValue }
    public var explanation: String {
        switch self {
        case .oneCore: "100% CPU equals one logical core; a process can exceed 100%."
        case .wholeSystem: "100% CPU equals all logical cores combined."
        }
    }
    public func processPercent(_ oneCorePercent: Double?, logicalCoreCount: Int) -> Double? {
        guard let value = oneCorePercent, value.isFinite, value >= 0 else { return nil }
        switch self {
        case .oneCore: return value
        case .wholeSystem:
            guard logicalCoreCount > 0 else { return nil }
            return value / Double(logicalCoreCount)
        }
    }
}

public enum RuntimeProcessGrouping: String, Codable, Sendable, CaseIterable, Identifiable {
    case individual = "Processes", parentTree = "Parent groups", application = "Applications"
    public var id: String { rawValue }
}

public struct RuntimeProcessMetrics: Sendable, Equatable {
    /// Nil if any group member lacks a sample; missing counters are not zero.
    public let cpuPercent: Double?
    public let residentBytes: UInt64?
    public init(cpuPercent: Double?, residentBytes: UInt64?) { self.cpuPercent = cpuPercent; self.residentBytes = residentBytes }
}

public struct RuntimeProcessGroup: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let representative: RuntimeProcess
    public let members: [RuntimeProcess]
    public let metrics: RuntimeProcessMetrics
    public var cpuPercent: Double? { metrics.cpuPercent }
    public var residentBytes: UInt64? { metrics.residentBytes }
}

public enum RuntimeProcessGroups {
    public static func processID(_ identity: RuntimeProcessIdentity) -> String { "process:\(identity.pid):\(identity.started)" }

    /// Groups metadata from one snapshot only. A newer process cannot be the
    /// parent of an older child; PID reuse never joins unrelated families.
    public static func build(_ processes: [RuntimeProcess], grouping: RuntimeProcessGrouping) -> [RuntimeProcessGroup] {
        let byPID = Dictionary(processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { left, right in left.id.started > right.id.started ? left : right })
        var buckets: [String: [RuntimeProcess]] = [:]
        var roots: [String: RuntimeProcess] = [:]
        var names: [String: String] = [:]
        var resolvedRoots: [RuntimeProcessIdentity: RuntimeProcess] = [:]
        func root(of process: RuntimeProcess) -> RuntimeProcess {
            if let cached = resolvedRoots[process.id] { return cached }
            var chain: [RuntimeProcess] = [], positions: [RuntimeProcessIdentity: Int] = [:], current = process
            while true {
                if let cached = resolvedRoots[current.id] {
                    for entry in chain { resolvedRoots[entry.id] = cached }; return cached
                }
                if let position = positions[current.id] {
                    // Defensive against inconsistent/cyclic kernel snapshots.
                    let cycleRoot = chain[position...].min { $0.id.pid < $1.id.pid } ?? current
                    for entry in chain { resolvedRoots[entry.id] = cycleRoot }; return cycleRoot
                }
                positions[current.id] = chain.count; chain.append(current)
                guard current.parentPID > 1, let parent = byPID[current.parentPID], parent.id != current.id,
                      parent.id.started <= current.id.started else {
                    for entry in chain { resolvedRoots[entry.id] = current }; return current
                }
                current = parent
            }
        }
        for process in processes {
            let id: String, name: String, representative: RuntimeProcess
            switch grouping {
            case .individual:
                id = processID(process.id); name = process.name; representative = process
            case .parentTree:
                representative = root(of: process)
                id = "parent:\(representative.id.pid):\(representative.id.started)"; name = representative.name
            case .application:
                if let path = process.executablePath, let range = path.range(of: ".app/", options: .caseInsensitive) {
                    let bundle = String(path[..<range.lowerBound]) + ".app"
                    id = "application:" + bundle
                    name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                    representative = process
                } else {
                    id = processID(process.id); name = process.name; representative = process
                }
            }
            buckets[id, default: []].append(process)
            names[id] = name
            if roots[id] == nil || (grouping == .application && representative.id.started < roots[id]!.id.started) { roots[id] = representative }
        }
        return buckets.keys.sorted().compactMap { id in
            guard let representative = roots[id], let name = names[id], let members = buckets[id] else { return nil }
            let ordered = members.sorted {
                if ($0.id == representative.id) != ($1.id == representative.id) { return $0.id == representative.id }
                return $0.id.pid < $1.id.pid
            }
            return RuntimeProcessGroup(id: id, name: name, representative: representative, members: ordered, metrics: aggregate(ordered))
        }
    }

    private static func aggregate(_ members: [RuntimeProcess]) -> RuntimeProcessMetrics {
        var cpu = 0.0, memory: UInt64 = 0, knownCPU = true, knownMemory = true
        for member in members {
            if let value = member.cpuPercent, value.isFinite, value >= 0 { cpu += value } else { knownCPU = false }
            if let bytes = member.residentBytes {
                let sum = memory.addingReportingOverflow(bytes); memory = sum.partialValue; knownMemory = knownMemory && !sum.overflow
            } else { knownMemory = false }
        }
        return RuntimeProcessMetrics(cpuPercent: knownCPU && cpu.isFinite ? cpu : nil, residentBytes: knownMemory ? memory : nil)
    }
}

public struct RuntimeProcessHistory: Sendable {
    public enum Metric: Sendable { case cpu, residentMemory }
    public struct Frame: Sendable {
        public let date: Date
        public let logicalCoreCount: Int
        public let metrics: [String: RuntimeProcessMetrics]
    }
    public private(set) var frames: [Frame] = []
    public let limit: Int
    public init(limit: Int = 120) { self.limit = min(600, max(1, limit)) }
    public mutating func removeAll() { frames.removeAll(keepingCapacity: true) }
    public mutating func append(date: Date, logicalCoreCount: Int, processes: [RuntimeProcess]) {
        var metrics: [String: RuntimeProcessMetrics] = [:]
        for grouping in RuntimeProcessGrouping.allCases {
            for group in RuntimeProcessGroups.build(processes, grouping: grouping) { metrics[group.id] = group.metrics }
        }
        frames.append(Frame(date: date, logicalCoreCount: logicalCoreCount, metrics: metrics))
        if frames.count > limit { frames.removeFirst(frames.count - limit) }
    }
    public func values(for groupID: String, metric: Metric, scale: RuntimeCPUScale = .oneCore) -> [Double?] {
        frames.map { frame in
            guard let value = frame.metrics[groupID] else { return nil }
            switch metric {
            case .cpu: return scale.processPercent(value.cpuPercent, logicalCoreCount: frame.logicalCoreCount)
            case .residentMemory: return value.residentBytes.map { Double($0) }
            }
        }
    }
}

public struct RuntimeTrendPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double
}

public enum RuntimeTrendSegments {
    /// Missing samples split the line; an exited/reused PID is never drawn as
    /// uninterrupted activity. Every position retains its original time slot.
    public static func make(values: [Double?], width: Double, height: Double, minimumCeiling: Double = 1) -> [[RuntimeTrendPoint]] {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return [] }
        let valid = values.compactMap { value -> Double? in value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let ceiling = max(1, minimumCeiling.isFinite ? minimumCeiling : 1, valid.max() ?? 0)
        var segments: [[RuntimeTrendPoint]] = [], current: [RuntimeTrendPoint] = []
        for (index, value) in values.enumerated() {
            if let value, value.isFinite, value >= 0 {
                let x = values.count > 1 ? Double(index) / Double(values.count - 1) * width : width
                current.append(RuntimeTrendPoint(x: x, y: height - min(1, value / ceiling) * height))
            } else if !current.isEmpty { segments.append(current); current = [] }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
