import Foundation

public struct DriveCapacity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let mountPoint: String
    public let totalBytes: Int64
    /// Basic available capacity; does not count purgeable bytes as already free.
    public let freeBytes: Int64
    public init(id: String, name: String, mountPoint: String, totalBytes: Int64, freeBytes: Int64) {
        self.id = id; self.name = name; self.mountPoint = mountPoint; self.totalBytes = totalBytes; self.freeBytes = freeBytes
    }
    public var freeRatio: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0 }
    public var pressure: DrivePressure {
        freeRatio < 0.05 ? .critical : freeRatio < 0.15 ? .low : .normal
    }
    public var isValid: Bool { !id.isEmpty && mountPoint.hasPrefix("/") && totalBytes > 0 && freeBytes >= 0 && freeBytes <= totalBytes }
    public var monitoringIdentityVerified: Bool { !id.hasPrefix("unverified:") }
}

public enum DrivePressure: String, Codable, Sendable { case normal, low, critical }

public struct DriveMonitorSettings: Sendable {
    public var enabled: Bool
    public var thresholdBytes: Int64
    /// Percentage points of drive capacity, not a percentage of previously free bytes.
    public var thresholdPercent: Double
    public var excludedDriveIDs: Set<String>
    public init(enabled: Bool = false, thresholdBytes: Int64 = 1_000_000_000,
                thresholdPercent: Double = 1, excludedDriveIDs: Set<String> = []) {
        self.enabled = enabled; self.thresholdBytes = thresholdBytes
        self.thresholdPercent = thresholdPercent; self.excludedDriveIDs = excludedDriveIDs
    }
}

public struct DriveSpaceEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case spaceDropped, pressureChanged }
    public let id: UUID
    public let timestamp: Date
    public let driveID: String
    public let driveName: String
    public let kind: Kind
    public let freeBytes: Int64
    public let droppedBytes: Int64
    public let pressure: DrivePressure
}

public struct DriveSpacePoint: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let driveID: String
    public let freeBytes: Int64
}

/// Pure reducer. Baselines accumulate small drops until they meet a threshold;
/// an increase resets the baseline, and an alert resets it to prevent repeats.
/// Capacity/identity changes establish a new baseline instead of a false alert.
public struct DriveMonitorHistory: Codable, Sendable {
    public static let eventLimit = 256
    public static let pointLimit = 1_440
    public private(set) var events: [DriveSpaceEvent] = []
    public private(set) var points: [DriveSpacePoint] = []
    public private(set) var latest: [DriveCapacity] = []
    private var baselines: [String: DriveCapacity] = [:]
    public init() {}

    @discardableResult
    public mutating func ingest(_ readings: [DriveCapacity], at date: Date,
                                settings: DriveMonitorSettings) -> [DriveSpaceEvent] {
        var seen = Set<String>()
        let valid = readings.filter { $0.isValid && seen.insert($0.id).inserted }
        let previous = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
        latest = valid
        let ids = Set(valid.map(\.id))
        baselines = baselines.filter { ids.contains($0.key) }
        var added: [DriveSpaceEvent] = []
        for drive in valid {
            guard settings.enabled, drive.monitoringIdentityVerified, !settings.excludedDriveIDs.contains(drive.id) else {
                baselines[drive.id] = drive; continue
            }
            points.append(DriveSpacePoint(timestamp: date, driveID: drive.id, freeBytes: drive.freeBytes))
            guard let baseline = baselines[drive.id], baseline.totalBytes == drive.totalBytes else {
                baselines[drive.id] = drive; continue
            }
            let drop = max(0, baseline.freeBytes - drive.freeBytes)
            let byteThreshold = max(1, settings.thresholdBytes)
            let percent = settings.thresholdPercent.isFinite ? max(0.01, settings.thresholdPercent) : 1
            let percentDrop = Double(drop) / Double(drive.totalBytes) * 100
            let alert = drop >= byteThreshold || percentDrop >= percent
            if alert {
                added.append(DriveSpaceEvent(id: UUID(), timestamp: date, driveID: drive.id, driveName: drive.name,
                    kind: .spaceDropped, freeBytes: drive.freeBytes, droppedBytes: drop, pressure: drive.pressure))
            } else if let old = previous[drive.id], old.totalBytes == drive.totalBytes,
                      old.pressure != drive.pressure {
                added.append(DriveSpaceEvent(id: UUID(), timestamp: date, driveID: drive.id, driveName: drive.name,
                    kind: .pressureChanged, freeBytes: drive.freeBytes, droppedBytes: drop, pressure: drive.pressure))
            }
            if alert || drive.freeBytes > (previous[drive.id]?.freeBytes ?? baseline.freeBytes) {
                baselines[drive.id] = drive
            }
        }
        events.append(contentsOf: added)
        events = Array(events.suffix(Self.eventLimit))
        points = Array(points.suffix(Self.pointLimit))
        return added
    }

    public mutating func clearEvents() { events = [] }

    /// Old persisted baselines must never become a current monitoring window.
    public mutating func resetBaselines() { baselines = [:]; latest = [] }
    public mutating func boundPersistedData() {
        events = Array(events.suffix(Self.eventLimit)); points = Array(points.suffix(Self.pointLimit))
        var seen = Set<String>()
        latest = Array(latest.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(64)); baselines = [:]
    }
}

public struct DriveMonitorResult: Sendable {
    public let history: DriveMonitorHistory
    public let newEvents: [DriveSpaceEvent]
    public let persistenceError: String?
}

/// Capacity probes only: no scan, deletion, wake assertion or privilege request.
/// Caller owns the opt-in timer. The bounded event history persists locally.
public actor DriveMonitor {
    private var history: DriveMonitorHistory
    private let storeURL: URL?
    private var loadWarning: String?
    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL
        var loaded = DriveMonitorHistory()
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let size = try storeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                loaded = try JSONDecoder().decode(DriveMonitorHistory.self, from: Data(contentsOf: storeURL))
                loaded.boundPersistedData()
            } catch { loadWarning = "Saved drive events could not be read. The previous file remains on this Mac." }
        }
        history = loaded
    }
    public func sample(settings: DriveMonitorSettings) -> DriveMonitorResult {
        let readings = Self.readCapacities()
        let added = history.ingest(readings, at: Date(), settings: settings)
        var warning = loadWarning
        // Preserve an unreadable prior file until the user explicitly clears it.
        if settings.enabled, loadWarning == nil, let storeURL {
            do {
                try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(history).write(to: storeURL, options: .atomic)
            } catch { warning = "Drive events are visible for this session but could not be saved." }
        }
        return DriveMonitorResult(history: history, newEvents: added, persistenceError: warning)
    }
    public func resetBaselines() { history.resetBaselines() }
    public func clearEvents() throws {
        history.clearEvents()
        if let storeURL { try JSONEncoder().encode(history).write(to: storeURL, options: .atomic) }
        loadWarning = nil
    }
    public static func readCapacities() -> [DriveCapacity] {
        SystemInventory.mountedVolumes().filter {
            !$0.isSystem && !$0.isNetwork && !$0.isReadOnly && !$0.mountPoint.contains(".timemachine")
        }.compactMap { volume in
            guard let total = volume.totalCapacity, let free = volume.availableCapacity else { return nil }
            let url = URL(fileURLWithPath: volume.mountPoint)
            let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            // BSD names can be reused after hotplug. Without a volume UUID we
            // show capacity, but never compare it as an alert baseline.
            let id = uuid.map { $0 + ":" + volume.mountPoint }
                ?? "unverified:" + volume.bsdName + ":" + volume.mountPoint
            let reading = DriveCapacity(id: id, name: volume.name, mountPoint: volume.mountPoint,
                totalBytes: total, freeBytes: free)
            return reading.isValid ? reading : nil
        }
    }
}
