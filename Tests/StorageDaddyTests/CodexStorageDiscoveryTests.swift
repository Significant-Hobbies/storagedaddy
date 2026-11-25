import Foundation
import Testing
@testable import StorageDaddy

struct CodexStorageDiscoveryTests {
    @Test func validatesModelNamesAndMeasuresOnlyLocalCacheChildren() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches")
        let real = cache.appendingPathComponent("Example")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 11_000_000).write(to: real.appendingPathComponent("payload"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("Alias"), withDestinationURL: real)
        try fm.createDirectory(at: cache.appendingPathComponent("Tiny"), withIntermediateDirectories: true)
        func response(_ names: [String]) throws -> String {
            let rows = names.map { ["component": $0, "kind": "compiler", "root": "libraryCaches"] }
            return String(decoding: try JSONEncoder().encode(["candidates": rows]), as: UTF8.self)
        }
        let input = try response(["Example", "Example", "Alias", "../Example", "/Example", "Tiny", "secret", "Example;touch sentinel"])
        let matches = try CodexStorageDiscovery.findings(input, home: home, exclusions: [])
        #expect(matches.map(\.title) == ["Example"])
        #expect(matches.first?.url.path == real.path)
        #expect((matches.first?.bytes ?? 0) >= 10_000_000)
        #expect(try CodexStorageDiscovery.findings(input, home: home, exclusions: [real.appendingPathComponent("payload").path]).isEmpty)
        for malformed in [#"{"candidates":[{"component":"Example","kind":"compiler","root":"elsewhere"}]}"#,
                          #"{"candidates":[{"component":"Example","kind":"compiler","root":"libraryCaches","command":"delete"}]}"#,
                          #"{"candidates":[],"shell":"ls"}"#, "invalid"] {
            #expect(throws: CodexStorageDiscovery.DiscoveryError.invalidResponse) {
                try CodexStorageDiscovery.findings(malformed, home: home, exclusions: [])
            }
        }
    }

    @Test func fixedPromptAndReadOnlyFlagsUseNoScannedNamesOrHomePath() {
        let args = CodexStorageDiscovery.arguments(schema: URL(fileURLWithPath: "/private/tmp/schema.json"))
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("read-only"))
        #expect(args.contains("shell_tool"))
        #expect(args.contains("hooks"))
        #expect(args.contains("apps"))
        #expect(args.contains("plugins"))
        #expect(args.contains("memories"))
        #expect(args.contains("web_search=\"disabled\""))
        #expect(args.last == CodexStorageDiscovery.prompt)
        #expect(!args.contains { $0.contains(FileManager.default.homeDirectoryForCurrentUser.path) })
    }
}
