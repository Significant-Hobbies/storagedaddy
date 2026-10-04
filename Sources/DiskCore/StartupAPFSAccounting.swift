import Foundation

/// One physical APFS pool inventory, including unmounted system volumes.
/// Free capacity is shared; never add it once per member volume.
public struct StartupAPFSAccounting: Sendable {
    public struct Volume: Sendable {
        public let name: String
        public let roles: [String]
        public let bytes: Int64
        public let device: String
    }
    public let measuredAt: Date
    public let total: Int64
    public let available: Int64
    public let volumes: [Volume]
    public let dataDevice: String
    public var used: Int64 { total - available }
    public var dataBytes: Int64 { volumes.first { $0.device == dataDevice }!.bytes }
    public var otherVolumes: [Volume] { volumes.filter { $0.device != dataDevice } }
    /// Signed: overlapping allocations or changing measurements must not be
    /// disguised as a positive "metadata" category.
    public var poolAdjustment: Int64 { used - volumes.reduce(0) { $0 + $1.bytes } }

    public static func collect(startup: MountedVolumeInfo) -> Self? {
        guard startup.isStartupData, startup.fsType == "apfs",
              let container = startup.apfsContainer,
              container.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist", container]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0, data.count <= 1_048_576 else { return nil }
        return parse(data, container: container, dataDevice: startup.bsdName)
    }

    static func parse(_ data: Data, container: String, dataDevice: String) -> Self? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]],
              let pool = containers.first(where: { $0["ContainerReference"] as? String == container }),
              let total = pool["CapacityCeiling"] as? Int64, total > 0,
              let available = pool["CapacityFree"] as? Int64, (0...total).contains(available),
              let members = pool["Volumes"] as? [[String: Any]], !members.isEmpty else { return nil }
        var volumes: [Volume] = []
        var seen = Set<String>()
        var allocated: Int64 = 0
        for member in members {
            guard let device = member["DeviceIdentifier"] as? String, seen.insert(device).inserted,
                  let name = member["Name"] as? String,
                  let bytes = member["CapacityInUse"] as? Int64, bytes >= 0,
                  let roles = member["Roles"] as? [String] else { return nil }
            let (sum, overflow) = allocated.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            allocated = sum
            volumes.append(Volume(name: name, roles: roles, bytes: bytes, device: device))
        }
        guard volumes.contains(where: { $0.device == dataDevice && $0.roles.contains("Data") }) else { return nil }
        return Self(measuredAt: Date(), total: total, available: available, volumes: volumes, dataDevice: dataDevice)
    }
}
