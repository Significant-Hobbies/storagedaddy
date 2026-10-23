import Darwin
import Foundation

public struct RuntimeProcessIdentity: Codable, Sendable, Equatable, Hashable {
    public let pid: Int32
    /// BSD process start timestamp, in microseconds; PID alone is never an identity.
    public let started: UInt64
    public init(pid: Int32, started: UInt64) { self.pid = pid; self.started = started }
}

public struct RuntimeProcess: Sendable, Equatable, Identifiable {
    public let id: RuntimeProcessIdentity
    public let parentPID: Int32
    public let uid: UInt32
    public let name: String
    public let executablePath: String?
    public let residentBytes: UInt64?
    /// Interval CPU, with 100% equal to one fully used logical core. Nil on the first sample.
    public let cpuPercent: Double?
    public init(id: RuntimeProcessIdentity, parentPID: Int32, uid: UInt32, name: String,
                executablePath: String?, residentBytes: UInt64?, cpuPercent: Double?) {
        self.id = id; self.parentPID = parentPID; self.uid = uid; self.name = name
        self.executablePath = executablePath; self.residentBytes = residentBytes; self.cpuPercent = cpuPercent
    }
    public var mayTerminate: Bool {
        guard id.pid > 1, id.pid != getpid(), uid == getuid(), let path = executablePath else { return false }
        return !["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: path.hasPrefix)
    }
}

public struct RuntimeMemory: Sendable, Equatable {
    public let physicalBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let freeBytes: UInt64
    public let swapUsedBytes: UInt64?
    /// Active + wired + compressed; this is not macOS's memory-pressure metric.
    public var usedBytes: UInt64 { activeBytes + wiredBytes + compressedBytes }
}

public struct RuntimeSnapshot: Sendable {
    public let timestamp: Date
    public let uptime: TimeInterval
    public let cpuPercent: Double?
    public let logicalCoreCount: Int
    public let memory: RuntimeMemory?
    public let processes: [RuntimeProcess]
    public let inaccessibleProcessCount: Int
    public let diskIO: StorageDashboardMetrics.IORates
    public let gpuUnavailableReason = "DiskHound's per-process GPU and VRAM counters are Windows-only. They are unavailable in this macOS view."
    public let processIOUnavailableReason = "Per-process disk throughput is unavailable in this macOS view. The rates shown here are aggregate physical-driver I/O."
}

/// Pure rate math shared by the sampler and tests. Never bridges a PID reuse,
/// missing counter, reset, suspend, or stale sample into a plausible zero.
public enum RuntimeRates {
    public static func cpu(previous: UInt64?, current: UInt64?, elapsed: Double,
                           sameIdentity: Bool = true) -> Double? {
        guard sameIdentity, let previous, let current, current >= previous,
              elapsed.isFinite, elapsed >= 0.1, elapsed <= 30 else { return nil }
        let value = Double(current - previous) / 1_000_000_000 / elapsed * 100
        return value.isFinite ? value : nil
    }
    public static func hostCPU(previousBusy: UInt64?, previousTotal: UInt64?,
                               busy: UInt64, total: UInt64) -> Double? {
        guard let previousBusy, let previousTotal, busy >= previousBusy, total > previousTotal else { return nil }
        let busyDelta = busy - previousBusy, totalDelta = total - previousTotal
        guard busyDelta <= totalDelta else { return nil }
        return Double(busyDelta) / Double(totalDelta) * 100
    }
}

public enum RuntimeActionError: LocalizedError {
    case unavailable, changedIdentity, protectedProcess, signalFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The process exited or its identity can no longer be read. Refresh the list."
        case .changedIdentity: "That PID now belongs to a different process. Nothing was sent."
        case .protectedProcess: "Only your own non-system processes can be ended from this view."
        case let .signalFailed(code): "Could not signal the process: \(String(cString: strerror(code)))."
        }
    }
}

/// No timers, privileged helper, process arguments, network, or automatic actions.
/// The UI starts/stops sampling with visible consumers. Every accessible process
/// is retained, including idle processes; unavailable metrics remain nil.
public actor RuntimeSampler {
    private struct Counter: Sendable { let cpu: UInt64?; let uptime: Double }
    private var counters: [RuntimeProcessIdentity: Counter] = [:]
    private var hostTicks: (busy: UInt64, total: UInt64)?
    private var ioSample: StorageDashboardMetrics.IOSample?
    public init() {}

    public func reset() { counters = [:]; hostTicks = nil; ioSample = nil }

    public func sample() -> RuntimeSnapshot {
        let uptime = ProcessInfo.processInfo.systemUptime
        var next: [RuntimeProcessIdentity: Counter] = [:]
        var rows: [RuntimeProcess] = []
        let pids = Self.processIDs()
        var inaccessible = 0
        for pid in pids {
            guard let raw = Self.readProcess(pid) else { inaccessible += 1; continue }
            let previous = counters[raw.identity]
            let cpu = RuntimeRates.cpu(previous: previous?.cpu, current: raw.cpu,
                                       elapsed: raw.sampledUptime - (previous?.uptime ?? raw.sampledUptime))
            next[raw.identity] = Counter(cpu: raw.cpu, uptime: raw.sampledUptime)
            rows.append(RuntimeProcess(id: raw.identity, parentPID: raw.parentPID, uid: raw.uid,
                                       name: raw.name, executablePath: raw.path, residentBytes: raw.memory, cpuPercent: cpu))
        }
        counters = next
        rows.sort { $0.id.pid < $1.id.pid }
        let ticks = Self.readHostTicks()
        let cpu = ticks.flatMap { RuntimeRates.hostCPU(previousBusy: hostTicks?.busy,
            previousTotal: hostTicks?.total, busy: $0.busy, total: $0.total) }
        hostTicks = ticks
        let io = StorageDashboardMetrics.collectIOSample()
        let rates = StorageDashboardMetrics.ioRates(previous: ioSample, current: io)
        ioSample = io
        return RuntimeSnapshot(timestamp: Date(), uptime: uptime, cpuPercent: cpu,
            logicalCoreCount: ProcessInfo.processInfo.activeProcessorCount, memory: Self.readMemory(),
            processes: rows, inaccessibleProcessCount: inaccessible, diskIO: rates)
    }

    /// Call only after a visible user confirmation; no escalation and no retries.
    /// Rechecks start identity and owner immediately before signalling.
    public static func sendSignal(to process: RuntimeProcess, force: Bool) throws {
        guard process.mayTerminate else { throw RuntimeActionError.protectedProcess }
        guard let current = readProcess(process.id.pid) else { throw RuntimeActionError.unavailable }
        guard current.identity == process.id, current.uid == process.uid else { throw RuntimeActionError.changedIdentity }
        let checked = RuntimeProcess(id: current.identity, parentPID: current.parentPID, uid: current.uid,
            name: current.name, executablePath: current.path, residentBytes: current.memory, cpuPercent: nil)
        guard checked.mayTerminate else { throw RuntimeActionError.protectedProcess }
        guard Darwin.kill(process.id.pid, force ? SIGKILL : SIGTERM) == 0 else {
            throw RuntimeActionError.signalFailed(errno)
        }
    }

    private struct RawProcess {
        let identity: RuntimeProcessIdentity
        let parentPID: Int32
        let uid: UInt32
        let name: String
        let path: String?
        let memory: UInt64?
        let cpu: UInt64?
        let sampledUptime: Double
    }
    private static func processIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var values = [Int32](repeating: 0, count: Int(count) + 512)
        let result = values.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard result > 0 else { return [] }
        return Array(values.prefix(min(Int(result), values.count))).filter { $0 > 0 }
    }
    private static func readProcess(_ pid: Int32) -> RawProcess? {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        guard start > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 1024)
        _ = proc_name(pid, &name, UInt32(name.count))
        var path = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
        var usage = rusage_info_v2()
        let hasUsage = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self,
                capacity: MemoryLayout<rusage_info_v2>.size / MemoryLayout<rusage_info_t?>.stride) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
            }
        }
        let sampledUptime = ProcessInfo.processInfo.systemUptime
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, infoSize) == infoSize,
              after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        let cpuSum = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        let rawName = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return RawProcess(identity: RuntimeProcessIdentity(pid: pid, started: start), parentPID: Int32(info.pbi_ppid),
            uid: info.pbi_uid, name: rawName.isEmpty ? "PID \(pid)" : rawName,
            path: pathLength > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil,
            memory: hasTask ? task.pti_resident_size : nil, cpu: hasUsage && !cpuSum.overflow ? cpuSum.partialValue : nil,
            sampledUptime: sampledUptime)
    }
    private static func readHostTicks() -> (busy: UInt64, total: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }
    private static func readMemory() -> RuntimeMemory? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        guard host_page_size(mach_host_self(), &page) == KERN_SUCCESS else { return nil }
        let bytes = UInt64(page)
        var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        return RuntimeMemory(physicalBytes: ProcessInfo.processInfo.physicalMemory,
            activeBytes: UInt64(info.active_count) * bytes, inactiveBytes: UInt64(info.inactive_count) * bytes,
            wiredBytes: UInt64(info.wire_count) * bytes, compressedBytes: UInt64(info.compressor_page_count) * bytes,
            freeBytes: UInt64(info.free_count) * bytes, swapUsedBytes: hasSwap ? swap.xsu_used : nil)
    }
}
