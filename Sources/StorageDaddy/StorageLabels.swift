import Foundation
import DiskCore

enum StorageLabels {
    /// Presentation only: filesystem actions always retain the original URL.
    static func location(_ path: String) -> String {
        var path = path
        if path.hasPrefix("/System/Volumes/Data/") { path.removeFirst("/System/Volumes/Data".count) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = path.split(separator: "/").map(String.init)
        if let fixture = parts.firstIndex(where: { $0.contains("(test fixture)") }) {
            parts = Array(parts[fixture...])
        } else if path == home || path.hasPrefix(home + "/") {
            parts = ["Home"] + path.dropFirst(home.count).split(separator: "/").map(String.init)
        } else if path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") {
            if let temp = parts.firstIndex(of: "T") { parts = ["Temporary files"] + Array(parts.dropFirst(temp + 1)) }
            else if let cache = parts.firstIndex(of: "C") { parts = ["Caches"] + Array(parts.dropFirst(cache + 1)) }
        }
        if parts.count > 5 { parts = [parts[0], "…"] + Array(parts.suffix(3)) }
        return parts.isEmpty ? "Startup storage" : parts.map(component).joined(separator: " › ")
    }

    static func name(_ node: DiskNode) -> String { component(node.name) }

    static func size(_ node: DiskNode, allocated: Bool, compact: Bool = false) -> String {
        if node.isContentsUnreadable == true { return compact ? "Not scanned" : "Not scanned · unreadable" }
        let bytes = allocated ? node.allocatedBytes : node.logicalBytes
        if node.isScanIncomplete == true {
            if bytes == 0 { return compact ? "Size unknown" : "Size unknown · incomplete scan" }
            return "\(DiskFormat.bytes(bytes)) scanned" + (compact ? "" : " · incomplete")
        }
        return DiskFormat.bytes(bytes)
    }

    static func session(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        if stem.hasPrefix("session-") { return "Session " + stem.dropFirst(8) }
        return "Session · " + stem.suffix(8)
    }

    private static func component(_ name: String) -> String {
        switch name {
        case ".PreviousSystemInformation": return "Previous system information"
        case ".com.apple.templatemigration.boot-install": return "macOS installation metadata"
        case "node_modules": return "node_modules"
        case ".venv", "venv": return "Python environment"
        case ".npm": return "npm cache"
        case ".pnpm-store": return "pnpm cache"
        case ".cache": return "Caches"
        case ".ollama": return "Ollama"
        case ".claude": return "Claude"
        case ".codex": return "Codex"
        case ".agents": return "Agent configuration"
        case ".cursor": return "Cursor"
        case ".system": return "Built-in"
        case "SDKExplicitPrecompiledModules": return "Precompiled SDK modules"
        case "ModuleCache.noindex": return "Compiler module cache"
        case "SourcePackages": return "Source packages"
        case ".build": return "Swift builds"
        case ".next": return "Next.js builds"
        case "DerivedData": return "Xcode builds"
        case "archived_sessions": return "Archived sessions"
        case "T", "tmp", "temp": return "Temporary files"
        case "Data": return "Startup data"
        default:
            if name.hasPrefix("-Users-") { return name.split(separator: "-").suffix(2).joined(separator: " ") }
            return name
        }
    }
}
