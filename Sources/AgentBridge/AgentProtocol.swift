import Foundation
import CryptoKit
import Security
import Darwin

public enum AgentJSON: Codable, Sendable, Equatable {
    case object([String: AgentJSON]), array([AgentJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([String: AgentJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([AgentJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> AgentJSON { if case .object(let v) = self { v[key] ?? .null } else { .null } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var array: [AgentJSON]? { if case .array(let v) = self { v } else { nil } }
    public var object: [String: AgentJSON]? { if case .object(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var int: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v, v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public static func integer(_ value: some BinaryInteger) -> AgentJSON { .number(Double(value)) }
    public static func encode<T: Encodable>(_ value: T) throws -> AgentJSON { try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(value)) }
    public var text: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "null" }
}

public struct AgentBridgeRequest: Codable, Sendable {
    public var operation: String
    public var token: String?
    public var payload: AgentJSON
    public init(operation: String, token: String? = nil, payload: AgentJSON = .object([:])) {
        self.operation = operation; self.token = token; self.payload = payload
    }
}

public enum AgentRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case explorer, guide, `operator`, admin
    public var id: String { rawValue }
    public var title: String {
        switch self { case .explorer: "Disk Explorer"; case .guide: "Cleanup Guide"; case .operator: "Cleanup Operator"; case .admin: "Cleanup Admin" }
    }
    public var permissions: Set<String> {
        switch self {
        case .explorer: ["read"]
        case .guide: ["read", "scan", "navigate"]
        case .operator: ["read", "scan", "navigate", "request_trash"]
        case .admin: ["read", "scan", "navigate", "request_trash", "request_permanent"]
        }
    }
}

public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    public let permission: String
    public let properties: [String: AgentJSON]
    public let required: [String]
    public var json: AgentJSON { .object([
        "name": .string(name), "description": .string(description),
        "inputSchema": .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(AgentJSON.string)), "additionalProperties": .bool(false)]),
        "annotations": .object(["readOnlyHint": .bool(permission == "read"), "destructiveHint": .bool(false), "openWorldHint": .bool(false)])
    ]) }
    public static let catalog: [AgentTool] = {
        let integer: AgentJSON = .object(["type": .string("integer"), "minimum": .integer(0)])
        let string: AgentJSON = .object(["type": .string("string"), "maxLength": .integer(4096)])
        let limit: AgentJSON = .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(200)])
        let ids: AgentJSON = .object(["type": .string("array"), "items": integer, "minItems": .integer(1), "maxItems": .integer(20), "uniqueItems": .bool(true)])
        func tool(_ name: String, _ description: String, _ permission: String = "read", _ properties: [String: AgentJSON] = [:], _ required: [String] = []) -> AgentTool {
            AgentTool(name: "storagedaddy_" + name, description: description, permission: permission, properties: properties, required: required)
        }
        return [
            tool("status", "Start here. Read permission, current scan, running work and agent request outcomes."),
            tool("read_skill", "Read cleanup or growth procedures before recommending changes.", "read", ["name": .object(["type": .string("string"), "enum": .array([.string("free-up-space"), .string("investigate-growth")])])], ["name"]),
            tool("scan_summary", "Current scan totals and largest scanned entries; allocation is attributed bytes, not guaranteed reclaimed space.", "read", ["limit": limit]),
            tool("list_folder", "List children of a directory in the current scan.", "read", ["nodeID": integer, "limit": limit, "offset": integer], ["nodeID"]),
            tool("search_files", "Search current scan metadata by name/path, extension and minimum attributed bytes; never reads file contents.", "read", ["query": string, "extension": string, "minimumBytes": integer, "limit": limit, "offset": integer]),
            tool("cleanup_suggestions", "Read existing cleanup candidates and guidance, without staging or running commands.", "read", ["limit": limit]),
            tool("dev_artifacts", "Read developer artifacts already identified by the app, grouped by project.", "read", ["limit": limit]),
            tool("measure_removal", "Measure fresh per-path and joint file allocation for up to 20 scanned items, accounting for hard links and full APFS clone references outside the selection. Reports uncertain bytes; never promises actual volume free space or removes files.", "read", ["nodeIDs": ids], ["nodeIDs"]),
            tool("scan_history", "Read bounded saved scan history, without arbitrary filesystem access.", "read", ["limit": limit]),
            tool("changes", "Compare per-file metadata from two saved scans of the same root; legacy records fall back to top-level totals.", "read", ["before": string, "after": string, "query": string, "limit": limit], ["before", "after"]),
            tool("duplicates", "Read duplicate groups found by the app.", "read", ["limit": limit]),
            tool("find_duplicates", "Start checksum duplicate discovery for the current scan.", "scan"),
            tool("start_scan", "Scan an already approved root; arbitrary paths require approval in the app first.", "scan", ["root": string], ["root"]),
            tool("cancel_scan", "Cancel a scan started by this agent session.", "scan"),
            tool("show", "Navigate to an existing StorageDaddy section or scanned folder.", "navigate", ["section": string, "nodeID": integer]),
            tool("reveal_path", "Reveal an existing scan node in Finder; never opens file contents.", "navigate", ["nodeID": integer], ["nodeID"]),
            tool("move_to_trash", "Request up to 20 scanned items for native review. This tool NEVER removes, moves or approves anything.", "request_trash", ["nodeIDs": ids, "reason": string], ["nodeIDs", "reason"]),
            tool("delete_permanently", "Request permanent deletion for native review. This tool NEVER deletes or approves anything.", "request_permanent", ["nodeIDs": ids, "reason": string], ["nodeIDs", "reason"])
        ]
    }()
}

public enum AgentSecurity {
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Could not create secure session identity.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    public static func failure(_ message: String) -> NSError { NSError(domain: "StorageDaddy.AgentAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    public static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StorageDaddy/Agent Bridge", isDirectory: true) }
    public static var socketPath: String { socketPath(for: directory) }
    /// Darwin limits Unix socket names to 104 bytes. Keep the authenticated
    /// endpoint short even when a home/profile/fixture path is very long.
    public static func socketPath(for policyDirectory: URL) -> String {
        let suffix = policyDirectory.standardizedFileURL == directory.standardizedFileURL ? "" : "-" + String(hash(policyDirectory.standardizedFileURL.path).prefix(16))
        return "/private/tmp/storagedaddy-agent-\(getuid())\(suffix)/agent.sock"
    }

    public static func preparePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw failure("The agent directory must belong to your account and be private (0700).")
        }
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try preparePrivateDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2 * 1024 * 1024 else { throw failure("Agent policy reached its storage limit.") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Cannot save agent policy.") }
        defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("Cannot save agent policy.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw failure("Cannot commit agent policy.") }
    }
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure("Agent policy is unavailable.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= 2 * 1024 * 1024 else { throw failure("Agent policy must be a private regular file.") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("Cannot read agent policy.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 2 * 1024 * 1024 else { throw failure("Agent policy is too large.") }
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum AgentProcedures {
    public static let cleanup = """
    Start with storagedaddy_status, ask how much space is needed, and obtain a fresh scan of an approved root. Review largest folders and developer artifacts. Read cleanup suggestions and duplicates; retain at least one verified duplicate. Cache commands are guidance, never automatic actions. Attributed allocation is not guaranteed reclaim: APFS clones, hard links, snapshots, purgeable space and open files can retain storage. Request only a small, explained set of scanned items. The owner must review and approve every removal in StorageDaddy. Prefer Trash; explain recovery and re-download/rebuild costs. Never request roots, standard home folders, sensitive data, or excluded paths. Verify free space after cleanup with a fresh scan.
    """
    public static let growth = """
    Start with storagedaddy_status and storagedaddy_scan_history. Compare two saved scans of the same root with storagedaddy_changes, respecting incomplete-scan evidence. Explain dates and whether a diff is full-index or compact top-level history. Investigate the largest positive changes using a fresh scan and developer artifacts. Keep changes in attributed allocation separate from actual volume free space; APFS clones, hard links and snapshots can change the relationship. Do not remove items while investigating. If cleanup is requested, follow the free-up-space procedure and use the native review queue.
    """
}
