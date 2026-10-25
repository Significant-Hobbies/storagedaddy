import Foundation

public struct NpxCacheEntry: Identifiable, Sendable {
    public let id: Int
    public let allocatedBytes: Int64
    public let modified: Date
    public let name: String
    public var packageSummary: String?
}

public enum NpxCacheReview {
    /// Bounded package manifests only; never npm configuration or credentials.
    public static func packageSummary(entry: URL) throws -> String {
        _ = try commandNames(entry: entry)
        let package = try manifest(entry.appendingPathComponent("package.json"), inside: entry)
        guard let dependencies = package["dependencies"] as? [String: Any] else { return "Package metadata unavailable" }
        return try dependencies.keys.sorted().map { name in
            let installed = try manifest(entry.appendingPathComponent("node_modules/" + name + "/package.json"), inside: entry)
            let version = installed["version"] as? String ?? ""
            let isVersion = version.count <= 100
                && version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
            return name + (isVersion ? " " + version : "")
        }.joined(separator: " · ")
    }

    public static func entries(in scan: ScanResult, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [NpxCacheEntry] {
        let cache = CleanupGuidance.normalized(home) + "/.npm/_npx"
        guard let root = scan.nodes.first(where: { $0.isDirectory && $0.name == "_npx"
            && CleanupGuidance.normalized(scan.url(for: $0.id).path) == cache }) else { return [] }
        return root.children.compactMap { id in
            guard scan.nodes.indices.contains(id), scan.nodes[id].isDirectory, !scan.nodes[id].isSymlink else { return nil }
            let node = scan.nodes[id]
            return NpxCacheEntry(id: id, allocatedBytes: node.allocatedBytes, modified: node.modified, name: node.name, packageSummary: nil)
        }.sorted { $0.modified < $1.modified }
    }

    static func affectedEntries(urls: [URL], home: String) throws -> [URL] {
        let cache = CleanupGuidance.normalized(home) + "/.npm/_npx"
        var entries = Set<URL>()
        for url in urls {
            let path = CleanupGuidance.normalized(url.path)
            if path == cache || cache.hasPrefix(path + "/") {
                guard FileManager.default.fileExists(atPath: cache) else { continue }
                let children = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: cache),
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard children.count <= 2_000 else { throw failure("Too many npx entries to verify at once. Review individual entries.") }
                for child in children {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw failure("A cache entry is a symlink. Inspect it before cleanup.") }
                    if values.isDirectory == true { entries.insert(child) }
                }
            } else if path.hasPrefix(cache + "/"), let first = path.dropFirst(cache.count + 1).split(separator: "/").first {
                entries.insert(URL(fileURLWithPath: cache).appendingPathComponent(String(first)))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// npm packages can run after Node closes the script file. Match their
    /// command paths and declared CLI names too, conservatively across versions.
    static func validate(entries: [URL], processOutput: String) throws {
        let rows = processOutput.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, Int32(parts[0]) != nil else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        guard !rows.isEmpty else { throw failure("The running-process list is unavailable. Keep these entries.") }
        for entry in entries {
            let names = try commandNames(entry: entry)
            for (pid, command) in rows {
                let path = CleanupGuidance.normalized(entry.path)
                let raw = command.replacingOccurrences(of: "/System/Volumes/Data/Users/", with: "/Users/")
                let pathUsed = raw.contains(path + "/")
                let named = names.contains { name in
                    raw.range(of: "(^|[\\s/])" + NSRegularExpression.escapedPattern(for: name) + "([\\s@]|$)", options: .regularExpression) != nil
                }
                if pathUsed || named { throw failure("Entry \(entry.lastPathComponent) may support a running npx tool (PID \(pid)). Quit that tool before cleanup; other versions with the same CLI are kept too.") }
            }
        }
    }

    static func commandNames(entry: URL) throws -> Set<String> {
        let package = try manifest(entry.appendingPathComponent("package.json"), inside: entry)
        guard let dependencies = package["dependencies"] as? [String: Any], !dependencies.isEmpty,
              dependencies.count <= 100 else { throw failure("This entry has no verifiable package metadata. Inspect it before cleanup.") }
        var names = Set<String>()
        for name in dependencies.keys {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard (parts.count == 1 || (parts.count == 2 && name.hasPrefix("@"))),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                    && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "@abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) } }) else {
                throw failure("The package name could not be verified. Inspect this entry before cleanup.")
            }
            names.insert(String(parts.last!))
            let installed = try manifest(entry.appendingPathComponent("node_modules/" + name + "/package.json"), inside: entry)
            if let bins = installed["bin"] as? [String: Any] { names.formUnion(bins.keys) }
        }
        return names.filter { !$0.isEmpty && $0.count <= 200 }
    }

    private static func manifest(_ url: URL, inside entry: URL) throws -> [String: Any] {
        let root = entry.standardizedFileURL.path
        let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
        guard url.standardizedFileURL.path.hasPrefix(entry.standardizedFileURL.path + "/"),
              url.resolvingSymlinksInPath().path == entry.resolvingSymlinksInPath().appendingPathComponent(relative).path else {
            throw failure("Package metadata traverses a symlink. Inspect this entry before cleanup.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536 else {
            throw failure("Package metadata is unavailable or too large. Inspect this entry before cleanup.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("Package metadata changed or is invalid. Inspect this entry before cleanup.")
        }
        return result
    }

    private static func failure(_ reason: String) -> NSError {
        NSError(domain: "NpxCacheReview", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
