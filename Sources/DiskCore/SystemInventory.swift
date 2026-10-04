import Darwin
import DiskArbitration
import Foundation
import IOKit

/// Read-only inventory of mounted volumes, physical storage devices and the
/// pressure signals macOS exposes. Nothing here mutates state, requires
/// elevated privileges or touches the network; every field may be nil and is
/// reported as unavailable rather than guessed.
public enum SystemInventory {

    public static func collect() -> SystemStorageReport {
        let volumes = mountedVolumes()
        return SystemStorageReport(
            collectedAt: Date(),
            volumes: volumes,
            containers: [],
            devices: storageDevices(),
            pressure: PressureProbe.collect(),
            startupAccounting: volumes.first(where: \.isStartupData).flatMap { StartupAPFSAccounting.collect(startup: $0) }
        ).withContainers()
    }

    // MARK: - Volumes

    public static func mountedVolumes() -> [MountedVolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsReadOnlyKey,
            .volumeIsBrowsableKey
        ]
        var urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        let startupPath = "/System/Volumes/Data"
        // Foundation can omit the hidden Data mount even with no skip option.
        // It is required to identify the startup pool and physical Data usage.
        if FileManager.default.fileExists(atPath: startupPath) {
            urls.insert(URL(fileURLWithPath: startupPath, isDirectory: true), at: 0)
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            var fsType = ""
            var bsdName = ""
            var stat = Darwin.statfs()
            let hasStat = statfs(path, &stat) == 0
            if hasStat {
                fsType = cStringField(stat.f_fstypename)
                bsdName = cStringField(stat.f_mntfromname).replacingOccurrences(of: "/dev/", with: "")
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            var encrypted: Bool? = nil
            var diskImage = false
            var volumeKind = fsType
            if let session,
               let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
               let desc = DADiskCopyDescription(disk) as? [String: Any] {
                encrypted = (desc["DAMediaEncrypted"] as? NSNumber)?.boolValue
                volumeKind = (desc["DAVolumeKind"] as? String) ?? fsType
                if let mediaPath = desc["DAMediaPath"] as? String {
                    diskImage = mediaPath.contains("IOHDIXController")
                }
                if let model = desc["DADeviceModel"] as? String, model == "Disk Image" { diskImage = true }
                if bsdName.isEmpty, let name = desc["DAMediaBSDName"] as? String { bsdName = name }
            }
            let browsable = values?.volumeIsBrowsable ?? true
            let isSystem = !browsable || path == "/" || path.hasPrefix("/System/") || path.hasPrefix("/private/")
                || path.hasPrefix("/dev") || path.hasPrefix("/vol")
            return MountedVolumeInfo(
                name: volumeName(url: url, values: values, startupPath: startupPath),
                mountPoint: path,
                fsType: volumeKind.isEmpty ? fsType : volumeKind,
                bsdName: bsdName,
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
                importantAvailableCapacity: values?.volumeAvailableCapacityForImportantUsage.map { Int64($0) },
                isStartupData: path == startupPath,
                isSystem: isSystem && path != startupPath,
                isInternal: values?.volumeIsInternal ?? !(values?.volumeIsRemovable ?? false),
                isRemovable: values?.volumeIsRemovable ?? false,
                isEjectable: values?.volumeIsEjectable ?? false,
                isReadOnly: values?.volumeIsReadOnly ?? false,
                isNetwork: Self.networkFilesystems.contains(volumeKind.isEmpty ? fsType : volumeKind),
                isEncrypted: encrypted,
                isDiskImage: diskImage,
                apfsContainer: Self.apfsContainerName(fsType: volumeKind.isEmpty ? fsType : volumeKind, bsdName: bsdName),
                inodeTotal: hasStat && stat.f_files > 0 ? stat.f_files : nil,
                inodeFree: hasStat && stat.f_files > 0 && stat.f_ffree <= stat.f_files ? stat.f_ffree : nil
            )
        }.sorted { lhs, rhs in
            func rank(_ v: MountedVolumeInfo) -> Int {
                if v.isStartupData { return 0 }
                if v.isSystem { return 3 }
                return v.isInternal ? 1 : 2
            }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func volumeName(url: URL, values: URLResourceValues?, startupPath: String) -> String {
        if url.standardizedFileURL.path == startupPath { return "Macintosh HD – Data" }
        if let name = values?.volumeName, !name.isEmpty { return name }
        let last = url.standardizedFileURL.lastPathComponent
        return last.isEmpty ? url.path : last
    }

    /// Filesystems that reach a remote server. Local synthesized filesystems
    /// (synthetic, autofs, devfs, mtmfs, cryptexfs) are not network storage.
    static let networkFilesystems: Set<String> = ["smbfs", "nfs", "webdav", "afpfs", "ftpfs", "osds"]

    /// APFS volumes are synthesized as diskNsM (and diskNsMsK snapshots);
    /// the container media is diskN.
    static func apfsContainerName(fsType: String, bsdName: String) -> String? {
        guard fsType == "apfs", bsdName.hasPrefix("disk") else { return nil }
        var digits = ""
        for ch in bsdName.dropFirst(4) {
            guard ch.isNumber else { break }
            digits.append(ch)
        }
        return digits.isEmpty ? nil : "disk\(digits)"
    }

    private static func cStringField<T>(_ value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    // MARK: - Physical devices

    /// Block storage devices with identity characteristics: internal NVMe,
    /// card readers and virtual disk-image devices. Reader/disk-image rows
    /// are flagged so the caller can present or skip them.
    public static func storageDevices() -> [StorageDeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [StorageDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let characteristics = IORegistryEntryCreateCFProperty(service, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let product = (characteristics["Product Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let medium = (characteristics["Medium Type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !product.isEmpty else { continue }
            let smartCapable = IORegistryEntryCreateCFProperty(service, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() != nil
            devices.append(StorageDeviceInfo(
                productName: product,
                vendor: (characteristics["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                revision: characteristics["Product Revision Level"] as? String ?? "",
                mediumType: medium,
                isSolidState: medium.lowercased() == "solid state",
                isDiskImage: product == "Disk Image",
                smartCapable: smartCapable
            ))
        }
        return devices
    }
}

// MARK: - Types

public struct SystemStorageReport: Sendable {
    public var collectedAt: Date
    public var volumes: [MountedVolumeInfo]
    public var containers: [APFSContainerInfo]
    public var devices: [StorageDeviceInfo]
    public var pressure: PressureInfo
    public var startupAccounting: StartupAPFSAccounting? = nil

    /// Group APFS volumes into their shared container. APFS volumes in one
    /// container share capacity, so container total/free come from members.
    func withContainers() -> SystemStorageReport {
        var copy = self
        var groups: [String: [MountedVolumeInfo]] = [:]
        for volume in volumes where volume.apfsContainer != nil {
            groups[volume.apfsContainer!, default: []].append(volume)
        }
        copy.containers = groups.map { name, members in
            APFSContainerInfo(
                name: name,
                totalCapacity: members.compactMap(\.totalCapacity).max(),
                freeCapacity: members.compactMap(\.availableCapacity).max(),
                importantFreeCapacity: members.compactMap(\.importantAvailableCapacity).max(),
                volumeNames: members.map(\.name).sorted()
            )
        }.sorted { $0.name < $1.name }
        return copy
    }
}

public struct MountedVolumeInfo: Sendable, Equatable {
    public var name: String
    public var mountPoint: String
    public var fsType: String
    public var bsdName: String
    public var totalCapacity: Int64?
    public var availableCapacity: Int64?
    public var importantAvailableCapacity: Int64?
    public var isStartupData: Bool
    public var isSystem: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isReadOnly: Bool
    public var isNetwork: Bool
    public var isEncrypted: Bool?
    public var isDiskImage: Bool
    public var apfsContainer: String?
    /// Raw statfs counts, not an invented fixed APFS inode capacity.
    /// Zero total or inconsistent counts are unavailable to metric consumers.
    public var inodeTotal: UInt64? = nil
    public var inodeFree: UInt64? = nil

    /// Space macOS can reclaim on demand (local snapshots, caches, cloud-only
    /// copies) but that still shows as used to basic capacity queries.
    public var purgeableCapacity: Int64? {
        guard let important = importantAvailableCapacity, let available = availableCapacity else { return nil }
        return max(0, important - available)
    }

    public var fsDisplayName: String {
        switch fsType {
        case "apfs": return "APFS"
        case "hfs": return "HFS+"
        case "exfat": return "exFAT"
        case "msdos": return "FAT"
        case "ntfs": return "NTFS"
        case "smbfs": return "SMB"
        case "nfs": return "NFS"
        case "webdav": return "WebDAV"
        case "devfs": return "devfs"
        case "synthetic": return "Synthetic"
        case "autofs": return "autofs"
        case "mtmfs": return "Mobile Time Machine"
        default: return fsType.isEmpty ? "Unknown" : fsType
        }
    }
}

public struct APFSContainerInfo: Sendable, Equatable {
    public var name: String
    public var totalCapacity: Int64?
    public var freeCapacity: Int64?
    public var importantFreeCapacity: Int64?
    public var volumeNames: [String]

    public var usedCapacity: Int64? {
        guard let totalCapacity, let freeCapacity else { return nil }
        return max(0, totalCapacity - freeCapacity)
    }
    public var purgeableCapacity: Int64? {
        guard let importantFreeCapacity, let freeCapacity else { return nil }
        return max(0, importantFreeCapacity - freeCapacity)
    }
}

public struct StorageDeviceInfo: Sendable, Equatable {
    public var productName: String
    public var vendor: String
    public var revision: String
    public var mediumType: String
    public var isSolidState: Bool
    public var isDiskImage: Bool
    public var smartCapable: Bool
}

// MARK: - Pressure

/// xsw_usage layout for vm.swapusage (see sysctl(3) / mach machine headers).
private struct XSWUsage {
    var total: UInt64 = 0
    var avail: UInt64 = 0
    var used: UInt64 = 0
    var pagesize: UInt32 = 0
    var encrypted: Int32 = 0
}

public struct PressureInfo: Sendable, Equatable {
    public var swapTotalBytes: UInt64?
    public var swapUsedBytes: UInt64?
    public var swapFreeBytes: UInt64?
    public var swapEncrypted: Bool?
    /// kern.memorystatus_level: kernel estimate of remaining memory headroom
    /// as a percentage; higher means more headroom.
    public var memoryHeadroomPercent: Int?
    public var bootTime: Date?
    /// Cumulative bytes across non-disk-image block drivers since boot.
    public var ioReadBytesSinceBoot: UInt64?
    public var ioWriteBytesSinceBoot: UInt64?
    /// Local APFS snapshot names (com.apple.TimeMachine.*); nil when the
    /// tmutil probe fails or is unavailable.
    public var localSnapshotNames: [String]?

    public var swapIsActive: Bool { (swapUsedBytes ?? 0) > 0 }
}

public enum PressureProbe {
    public static func collect() -> PressureInfo {
        var info = PressureInfo()
        if let swap = swapUsage() {
            info.swapTotalBytes = swap.total
            info.swapUsedBytes = swap.used
            info.swapFreeBytes = swap.avail
            info.swapEncrypted = swap.encrypted != 0
        }
        info.memoryHeadroomPercent = sysctlInt32("kern.memorystatus_level").map(Int.init)
        info.bootTime = bootTime()
        let io = blockIOStats()
        info.ioReadBytesSinceBoot = io?.read
        info.ioWriteBytesSinceBoot = io?.written
        info.localSnapshotNames = localSnapshots()
        return info
    }

    static func swapUsage() -> (total: UInt64, avail: UInt64, used: UInt64, encrypted: Int32)? {
        var usage = XSWUsage()
        var size = MemoryLayout<XSWUsage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.total, usage.avail, usage.used, usage.encrypted)
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// Sum IOBlockStorageDriver Statistics across real (non disk-image)
    /// devices. These counters reset at boot, not lifetime totals.
    static func blockIOStats() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var parent: io_registry_entry_t = 0
            var isDiskImage = false
            if IORegistryEntryGetParentEntry(service, "IOService", &parent) == kIOReturnSuccess, parent != 0 {
                if let characteristics = IORegistryEntryCreateCFProperty(parent, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   (characteristics["Product Name"] as? String) == "Disk Image" { isDiskImage = true }
                IOObjectRelease(parent)
            }
            guard !isDiskImage,
                  let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            if let bytes = stats["Bytes (Read)"] as? NSNumber { read += bytes.uint64Value; found = true }
            if let bytes = stats["Bytes (Write)"] as? NSNumber { written += bytes.uint64Value; found = true }
        }
        return found ? (read, written) : nil
    }

    /// tmutil lists local snapshots without elevated privileges. Output is a
    /// header line followed by one snapshot name per line.
    static func localSnapshots(volume: String = "/") -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let names = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("snapshots") }
        return names
    }
}
