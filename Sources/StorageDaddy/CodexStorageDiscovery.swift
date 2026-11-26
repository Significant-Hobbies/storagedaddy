import Darwin
import DiskCore
import Foundation

/// Codex proposes common cache names. Every location and measurement in the
/// resulting read-only review comes from this Mac.
enum CodexStorageDiscovery {
    struct Finding: Identifiable, Sendable {
        var id: String { url.path }
        let url: URL
        let title: String
        let explanation: String
        let bytes: Int64
    }

    enum DiscoveryError: LocalizedError, Equatable {
        case missingCLI, unavailable, invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingCLI: "Install the Codex CLI to use Codex discovery."
            case .unavailable: "Codex could not finish the request. Check your Codex sign-in and connection, then try again."
            case .invalidResponse: "Codex returned an unexpected response. Try discovery again."
            }
        }
    }

    private enum CacheKind: String, CaseIterable {
        case browser, compiler, downloads, package, models

        var description: String {
            switch self {
            case .browser: "Codex suggests this folder may contain browser caches."
            case .compiler: "Codex suggests this folder may contain compiler or build caches."
            case .downloads: "Codex suggests this folder may contain downloaded tool assets."
            case .package: "Codex suggests this folder may contain a package manager’s cache."
            case .models: "Codex suggests this folder may contain downloaded models."
            }
        }
    }

    static let prompt = """
    Suggest up to 12 frequently large macOS cache directories used by developer tools,
    compilers, browsers, and local AI applications. This is a general product-knowledge
    question. Respond only with the requested JSON. Use a single direct child name of
    the standard user cache directory (libraryCaches) or XDG cache directory (dotCache).
    Do not inspect the machine, invoke tools, or request local data.
    """

    static func discover(home: URL, exclusions: [String]) async throws -> [Finding] {
        let binary = FolderExplainer.detectAgents(home: home.path).first { $0.0 == .codex }?.1
        guard let binary else { throw DiscoveryError.missingCLI }
        let worker = Task.detached(priority: .utility) { () throws -> [Finding] in
            // Avoid inheriting a project or putting the user's home path in the working directory.
            let temporary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("StorageDaddy-Codex-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let schemaURL = temporary.appendingPathComponent("schema.json")
            try Data(schema.utf8).write(to: schemaURL, options: .withoutOverwriting)
            let response = try PackageToolCommand.run(executable: binary, arguments: arguments(schema: schemaURL),
                directory: temporary, timeout: 90, maximumOutputBytes: 32_768, requireCompleteOutput: true,
                mergeStandardError: false)
            try Task.checkCancellation()
            guard response.status == 0 else { throw DiscoveryError.unavailable }
            return try findings(response.output, home: home, exclusions: exclusions)
        }
        do { return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
        catch is CancellationError { throw CancellationError() }
        catch let error as DiscoveryError { throw error }
        catch {
            try Task.checkCancellation()
            throw DiscoveryError.unavailable
        }
    }

    static func arguments(schema: URL) -> [String] {
        let disabled = ["shell_tool", "unified_exec", "hooks", "apps", "plugins", "memories", "browser_use",
                        "computer_use", "multi_agent", "multi_agent_v2", "image_generation"]
        return ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only"]
            + disabled.flatMap { ["--disable", $0] }
            + ["--config", "web_search=\"disabled\"", "--config", "project_doc_max_bytes=0",
               "--output-schema", schema.path, "--color", "never", prompt]
    }

    private static let schema = """
    {"type":"object","properties":{"candidates":{"type":"array","maxItems":12,"items":{"type":"object","properties":{
    "root":{"type":"string","enum":["libraryCaches","dotCache"]},
    "component":{"type":"string"},"kind":{"type":"string","enum":["browser","compiler","downloads","package","models"]}},
    "required":["root","component","kind"],"additionalProperties":false}}},
    "required":["candidates"],"additionalProperties":false}
    """

    static func findings(_ response: String, home: URL, exclusions: [String]) throws -> [Finding] {
        guard response.utf8.count <= 32_768,
              let decoded = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              Set(decoded.keys) == ["candidates"], let suggestions = decoded["candidates"] as? [[String: String]],
              suggestions.count <= 12, home.isFileURL else { throw DiscoveryError.invalidResponse }
        let policy = FolderExclusions(paths: exclusions)
        var seen = Set<String>()
        var result: [Finding] = []
        for suggestion in suggestions {
            try Task.checkCancellation()
            guard Set(suggestion.keys) == ["root","component","kind"],
                  let root = suggestion["root"], ["libraryCaches", "dotCache"].contains(root),
                  let name = suggestion["component"],
                  let kind = CacheKind(rawValue: suggestion["kind"] ?? "") else { throw DiscoveryError.invalidResponse }
            guard validComponent(name) else { continue }
            let cache = home.appendingPathComponent(root == "libraryCaches" ? "Library/Caches" : ".cache")
            let url = cache.appendingPathComponent(name)
            guard seen.insert(url.path).inserted, !policy.blocksCleanup(url),
                  url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path,
                  let before = identity(url) else { continue }
            // RemovalMeasurement enumerates allocation metadata with no-follow descriptors,
            // protecting sensitive entries; the reported size is the observed allocation.
            let report: LiveRemovalReport
            do { report = try RemovalMeasurement.measure(paths: [url], excludedFolders: exclusions, maximumEntries: 100_000) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            guard let after = identity(url), before == after, report.total.sizeBytes >= 10_000_000 else { continue }
            let detail = kind.description + (report.incomplete ? " Only accessible items were measured." : "")
            result.append(Finding(url: url, title: name, explanation: detail, bytes: report.total.sizeBytes))
        }
        return result.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
    }

    private static func validComponent(_ value: String) -> Bool {
        guard value.utf8.count <= 96, !value.contains(".."),
              value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]*\z"#, options: .regularExpression) != nil else { return false }
        let name = value.lowercased()
        return !["credential","secret","password","token","keychain","private-key","auth","wallet","1password","bitwarden"].contains(where: name.contains)
    }

    private static func identity(_ url: URL) -> (UInt64, UInt64)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { return nil }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }
}
