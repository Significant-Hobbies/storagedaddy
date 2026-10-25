import Foundation

/// Known footprints describe purpose, never abandonment or permission to delete.
/// Only bounded data roots are findings; configuration is deliberately separate.
public struct ToolStorageProfile: Sendable {
    public let tool: String
    public let root: String
    public let dataEntries: Set<String>?
    public let consequence: String
}

public enum ToolStorage {
    public static let profiles: [ToolStorageProfile] = [
        .init(tool: "Cursor snapshots", root: "Library/Application Support/Cursor/snapshots", dataEntries: nil,
              consequence: "Editor snapshots can contain recovery history. Quit Cursor and confirm these restore points are no longer needed. Other Cursor data stays separate."),
        .init(tool: "Claude VM bundles", root: "Library/Application Support/Claude/vm_bundles", dataEntries: nil,
              consequence: "These bundles support Claude’s local virtual machine features. Quit Claude and its VM first. Later use may require downloading the bundles again; other Claude data stays separate."),
        .init(tool: "iOS DeviceSupport", root: "Library/Developer/Xcode/iOS DeviceSupport", dataEntries: nil,
              consequence: "Device debugging support for connected iOS versions. Quit Xcode and review which versions you still debug. Reconnecting a device may require preparing support again."),
        .init(tool: "GorTex", root: ".gortex",
              dataEntries: ["store", "cache", "memories", "notebook-cache", "sidecar.sqlite", "sidecar.sqlite-wal", "sidecar.sqlite-shm"],
              consequence: "Persistent index, memory and local database state. Quit GorTex before cleanup. Review the data you want to lose; configuration and credentials are kept."),
        .init(tool: "sellTraces", root: ".selltraces",
              dataEntries: ["traces.db", "traces.db-wal", "traces.db-shm", "bin"],
              consequence: "Historical traces and the local tool binary. Quit sellTraces before cleanup. Removing the database loses recorded traces; configuration and credentials are kept.")
    ]
    private static let candidateNames: Set<String> = {
        var names = Set<String>()
        for profile in profiles {
            if let name = profile.root.split(separator: "/").last { names.insert(String(name).lowercased()) }
            if let entries = profile.dataEntries { names.formUnion(entries) }
        }
        return names
    }()

    /// Cheap name filter before constructing paths in a large scan.
    public static func mayRecognize(name: String) -> Bool {
        candidateNames.contains(name.lowercased())
    }

    public static func recognizedRoot(path: String) -> ToolStorageProfile? {
        let parts = components(path)
        return profiles.first { profile in
            let root = components(profile.root)
            if let entries = profile.dataEntries {
                return parts.count > root.count && Array(parts.dropLast()).ends(with: root)
                    && entries.contains(parts.last ?? "")
            }
            return parts.ends(with: root)
        }
    }

    public static func containingData(path: String) -> ToolStorageProfile? {
        let parts = components(path)
        return profiles.first { profile in
            guard let offset = rootOffset(profile, in: parts) else { return false }
            let tail = parts.dropFirst(offset + components(profile.root).count)
            return profile.dataEntries.map { $0.contains(tail.first ?? "") } ?? true
        }
    }

    /// A tool-root selection would also remove small, valuable configuration.
    /// This remains blocked even when an incomplete-scan warning is acknowledged.
    public static func validateCleanup(path: String) throws {
        let parts = components(path)
        for profile in profiles where profile.dataEntries != nil {
            guard let offset = rootOffset(profile, in: parts) else { continue }
            let tail = parts.dropFirst(offset + components(profile.root).count)
            guard let first = tail.first, profile.dataEntries!.contains(first) else {
                throw NSError(domain: "ToolStorage", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Keep \(profile.tool)’s configuration and credentials. Review its recognized data entries in Developer Insights instead of removing the whole tool folder."])
            }
        }
    }

    static func validateActiveUse(urls: [URL], processOutput: String) throws {
        let owners = Set(urls.compactMap { containingData(path: $0.path)?.tool })
        guard !owners.isEmpty else { return }
        let rows = processOutput.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, Int32(parts[0]) != nil else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        guard !rows.isEmpty else { throw NSError(domain: "CleanupActiveUse", code: 1, userInfo: [NSLocalizedDescriptionKey: "The owning tool’s process state is unavailable. Keep its data and try again."]) }
        for owner in owners {
            let pattern: String
            switch owner {
            case "Cursor snapshots": pattern = "(^|[\\s/])Cursor([\\s/]|$)"
            case "Claude VM bundles": pattern = "/Claude\\.app/Contents/"
            case "iOS DeviceSupport": pattern = "/Contents/MacOS/Xcode([\\s]|$)"
            case "GorTex": pattern = "(^|[\\s/])gortex([\\s]|$)"
            case "sellTraces": pattern = "(^|[\\s/])selltraces([\\s]|$)"
            default: continue
            }
            if let row = rows.first(where: { $0.1.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) {
                throw NSError(domain: "CleanupActiveUse", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Quit \(owner)’s owning tool (PID \(row.0)) before cleanup, even when its data files are currently closed."])
            }
        }
    }

    private static func components(_ path: String) -> [String] {
        (path.hasPrefix("/") ? CleanupGuidance.normalized(path) : path).lowercased().split(separator: "/").map(String.init)
    }

    private static func rootOffset(_ profile: ToolStorageProfile, in parts: [String]) -> Int? {
        let root = components(profile.root)
        guard parts.count >= root.count else { return nil }
        return (0...(parts.count - root.count)).first { Array(parts[$0..<($0 + root.count)]) == root }
    }
}

private extension Array where Element == String {
    func ends(with suffix: [String]) -> Bool { count >= suffix.count && Array(self.suffix(suffix.count)) == suffix }
}
