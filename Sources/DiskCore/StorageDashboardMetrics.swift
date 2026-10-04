import Foundation
import IOKit

/// Pure calculations and explicitly invoked probes; no timers or persistence.
public enum StorageDashboardMetrics {
    public struct Inodes: Sendable, Equatable {
        public let total: UInt64
        public let free: UInt64
        public var used: UInt64 { total - free }
        public var usedRatio: Double { Double(used) / Double(total) }
    }

    public static func inodes(total: UInt64?, free: UInt64?) -> Inodes? {
        // Some pseudo filesystems report a sentinel rather than a capacity.
        guard let total, total > 0, total < UInt64(Int64.max), let free, free <= total else { return nil }
        return Inodes(total: total, free: free)
    }

    public struct DriverCounter: Sendable, Equatable {
        /// IORegistry entry ID, never a synthesized APFS disk number.
        public let registryID: UInt64
        public let readBytes: UInt64?
        public let writtenBytes: UInt64?
        public init(registryID: UInt64, readBytes: UInt64?, writtenBytes: UInt64?) {
            self.registryID = registryID
            self.readBytes = readBytes
            self.writtenBytes = writtenBytes
        }
    }

    public struct VolumeCounter: Sendable, Equatable {
        public let bsdName: String
        public let registryID: UInt64
        public let readBytes: UInt64?
        public let writtenBytes: UInt64?
        public init(bsdName: String, registryID: UInt64, readBytes: UInt64?, writtenBytes: UInt64?) {
            self.bsdName = bsdName; self.registryID = registryID
            self.readBytes = readBytes; self.writtenBytes = writtenBytes
        }
    }

    public struct VolumeRates: Sendable, Equatable {
        public let bsdName: String
        public let read: Rate
        public let write: Rate
        public let interval: TimeInterval?
    }

    public struct IOSample: Sendable, Equatable {
        /// Monotonic seconds; use systemUptime, not a wall-clock Date delta.
        public let uptime: TimeInterval
        /// Boot identity plus registry IDs prevents deltas across restarts/hotplug.
        public let bootTime: Date?
        public let drivers: [DriverCounter]
        public let volumes: [VolumeCounter]
        public init(uptime: TimeInterval, bootTime: Date?, drivers: [DriverCounter], volumes: [VolumeCounter] = []) {
            self.uptime = uptime
            self.bootTime = bootTime
            self.drivers = drivers
            self.volumes = volumes
        }
    }

    public enum IOUnavailable: String, Sendable, Equatable {
        case waitingForSample = "Waiting for two samples"
        case invalidDuration = "Sample interval unavailable"
        case identityChanged = "Driver or boot identity changed"
        case missingCounters = "Driver counters unavailable"
        case counterReset = "Driver counters reset"
    }

    public enum Rate: Sendable, Equatable {
        case measured(Double)
        case unavailable(IOUnavailable)
    }

    public struct IORates: Sendable, Equatable {
        public let read: Rate
        public let write: Rate
        public let interval: TimeInterval?
        public var volumes: [VolumeRates] = []
        public static var waiting: Self {
            Self(read: .unavailable(.waitingForSample), write: .unavailable(.waitingForSample), interval: nil)
        }
        public let attribution = "Aggregate observed physical-driver I/O"
        /// Logical APFS-volume traffic and physical-driver traffic have different scopes.
        public var perVolumeUnavailableReason: String {
            "APFS volume block I/O is measured separately when exact BSD identity is verified; physical-driver totals are not assigned to volumes."
        }
    }

    public static func ioRates(previous: IOSample?, current: IOSample) -> IORates {
        var result = driverRates(previous: previous, current: current)
        result.volumes = volumeRates(previous: previous, current: current)
        return result
    }

    /// Exact IORegistry BSD name and entry identity only. A mounted snapshot's
    /// suffixed BSD name is never guessed to belong to a base APFS volume.
    public static func volumeRates(previous: IOSample?, current: IOSample) -> [VolumeRates] {
        current.volumes.map { volume in
            func unavailable(_ reason: IOUnavailable) -> VolumeRates {
                VolumeRates(bsdName: volume.bsdName, read: .unavailable(reason), write: .unavailable(reason), interval: nil)
            }
            guard let previous else { return unavailable(.waitingForSample) }
            let duration = current.uptime - previous.uptime
            guard previous.uptime.isFinite, current.uptime.isFinite, duration.isFinite, duration > 0 else { return unavailable(.invalidDuration) }
            guard let boot = previous.bootTime, let newBoot = current.bootTime else { return unavailable(.missingCounters) }
            guard boot == newBoot, volume.registryID != 0, !volume.bsdName.isEmpty else { return unavailable(.identityChanged) }
            let old = previous.volumes.filter { $0.bsdName == volume.bsdName }
            guard old.count == 1, current.volumes.filter({ $0.bsdName == volume.bsdName }).count == 1,
                  old[0].registryID == volume.registryID,
                  previous.volumes.filter({ $0.registryID == volume.registryID }).count == 1,
                  current.volumes.filter({ $0.registryID == volume.registryID }).count == 1 else { return unavailable(.identityChanged) }
            func rate(_ key: KeyPath<VolumeCounter, UInt64?>) -> Rate {
                guard let before = old[0][keyPath: key], let after = volume[keyPath: key] else { return .unavailable(.missingCounters) }
                guard after >= before else { return .unavailable(.counterReset) }
                let value = Double(after - before) / duration
                return value.isFinite ? .measured(value) : .unavailable(.invalidDuration)
            }
            return VolumeRates(bsdName: volume.bsdName, read: rate(\.readBytes), write: rate(\.writtenBytes), interval: duration)
        }
    }

    private static func driverRates(previous: IOSample?, current: IOSample) -> IORates {
        guard let previous else { return .waiting }
        func unavailable(_ reason: IOUnavailable) -> IORates {
            IORates(read: .unavailable(reason), write: .unavailable(reason), interval: nil)
        }
        let duration = current.uptime - previous.uptime
        guard previous.uptime.isFinite, current.uptime.isFinite, duration.isFinite, duration > 0 else {
            return unavailable(.invalidDuration)
        }
        guard let boot = previous.bootTime, let currentBoot = current.bootTime,
              !previous.drivers.isEmpty, !current.drivers.isEmpty else {
            return unavailable(.missingCounters)
        }
        guard boot == currentBoot else { return unavailable(.identityChanged) }
        let oldIDs = Set(previous.drivers.map(\.registryID))
        let newIDs = Set(current.drivers.map(\.registryID))
        guard oldIDs.count == previous.drivers.count, newIDs.count == current.drivers.count,
              !oldIDs.contains(0), oldIDs == newIDs else { return unavailable(.identityChanged) }
        let old = Dictionary(uniqueKeysWithValues: previous.drivers.map { ($0.registryID, $0) })
        func rate(_ key: KeyPath<DriverCounter, UInt64?>) -> Rate {
            var delta = 0.0
            for driver in current.drivers {
                guard let before = old[driver.registryID]?[keyPath: key], let after = driver[keyPath: key] else {
                    return .unavailable(.missingCounters)
                }
                guard after >= before else { return .unavailable(.counterReset) }
                // Subtract in UInt64 before converting to preserve small deltas above 2^53.
                delta += Double(after - before)
            }
            let value = delta / duration
            return value.isFinite ? .measured(value) : .unavailable(.invalidDuration)
        }
        return IORates(read: rate(\.readBytes), write: rate(\.writtenBytes), interval: duration)
    }

    /// Uses the same IOBlockStorageDriver Statistics source as PressureProbe,
    /// retaining registry identity and missing channels instead of summing them
    /// into ambiguous since-boot totals. Caller owns scheduling and cancellation.
    public static func collectIOSample() -> IOSample {
        let boot = PressureProbe.bootTime()
        var iterator: io_iterator_t = 0
        var drivers: [DriverCounter] = []
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var parent: io_registry_entry_t = 0
                // Fail closed if disk-image exclusion cannot be established.
                guard IORegistryEntryGetParentEntry(service, "IOService", &parent) == kIOReturnSuccess, parent != 0 else { continue }
                let characteristics = IORegistryEntryCreateCFProperty(parent, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                IOObjectRelease(parent)
                guard let product = characteristics?["Product Name"] as? String, product != "Disk Image" else { continue }
                var identity: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &identity) == kIOReturnSuccess else { continue }
                let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                func counter(_ name: String) -> UInt64? {
                    guard let value = stats?[name] as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
                    return value.uint64Value
                }
                drivers.append(DriverCounter(registryID: identity, readBytes: counter("Bytes (Read)"), writtenBytes: counter("Bytes (Write)")))
            }
        }
        var volumeIterator: io_iterator_t = 0
        var volumes: [VolumeCounter] = []
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleAPFSVolume"), &volumeIterator) == kIOReturnSuccess {
            defer { IOObjectRelease(volumeIterator) }
            while case let service = IOIteratorNext(volumeIterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let bsd = IORegistryEntryCreateCFProperty(service, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
                var identity: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &identity) == kIOReturnSuccess, identity != 0 else { continue }
                let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                func counter(_ name: String) -> UInt64? {
                    guard let number = stats?[name] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                          number.doubleValue >= 0, number.doubleValue < Double(UInt64.max) else { return nil }
                    return number.uint64Value
                }
                volumes.append(VolumeCounter(bsdName: bsd, registryID: identity,
                    readBytes: counter("Bytes read from block device"), writtenBytes: counter("Bytes written to block device")))
            }
        }
        return IOSample(uptime: ProcessInfo.processInfo.systemUptime, bootTime: boot, drivers: drivers, volumes: volumes)
    }

    public struct ScoreComponent: Sendable, Equatable, Identifiable {
        public let id: String
        public let explanation: String
        /// Each component contributes 0...25. nil means unknown, never measured zero.
        public let points: Double?
    }

    public struct Score: Sendable, Equatable {
        public let components: [ScoreComponent]
        public var measuredCount: Int { components.filter { $0.points != nil }.count }
        public var coverage: Double { Double(measuredCount) / 4 }
        /// Fixed denominator: missing inputs earn no points, but are not failures.
        /// Partial results cannot read as fully measured 100/100.
        public var earnedPoints: Double? {
            measuredCount == 0 ? nil : components.compactMap(\.points).reduce(0, +)
        }
        public var isComplete: Bool { measuredCount == 4 }
    }

    /// Transparent storage-readiness heuristic, not a drive-health diagnosis.
    /// Scope: one selected capacity pool, explicitly supplied NVMe wear, and
    /// snapshots for that same selected volume. Caller must verify association;
    /// do not match health deviceName to APFS synthesized disk numbers.
    /// Equal 25-point weights: free ratio reaches full credit at 20%; purgeable
    /// ratio earns 1-ratio; wear earns max(0,1-used/100); snapshot count earns
    /// 1/(1+count/10). Snapshot presence is review context, not evidence of harm.
    /// Ratios use basic available bytes (not important/reclaimable free bytes).
    public static func score(totalBytes: Int64?, freeBytes: Int64?, purgeableBytes: Int64?,
                             nvmePercentUsed: Int?, snapshotCount: Int?) -> Score {
        func ratio(_ bytes: Int64?) -> Double? {
            guard let totalBytes, totalBytes > 0, let bytes, bytes >= 0, bytes <= totalBytes else { return nil }
            return Double(bytes) / Double(totalBytes)
        }
        let free = ratio(freeBytes).map { min(1, $0 / 0.2) * 25 }
        let purgeable = ratio(purgeableBytes).map { (1 - $0) * 25 }
        let wear = nvmePercentUsed.flatMap { $0 >= 0 && $0 <= 255 ? max(0, 1 - Double($0) / 100) * 25 : nil }
        let snapshots = snapshotCount.flatMap { $0 >= 0 ? 25 / (1 + Double($0) / 10) : nil }
        return Score(components: [
            ScoreComponent(id: "Free space", explanation: "25 × min(1, free ratio ÷ 20%)", points: free),
            ScoreComponent(id: "Purgeable space", explanation: "25 × (1 − purgeable ratio)", points: purgeable),
            ScoreComponent(id: "NVMe wear", explanation: "25 × max(0, 1 − percentage used ÷ 100)", points: wear),
            ScoreComponent(id: "Local snapshots", explanation: "25 ÷ (1 + snapshot count ÷ 10)", points: snapshots)
        ])
    }
}
