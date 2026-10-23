import Foundation
import Darwin

public enum AgentExtensionBuilder {
    /// Builds a standard MCP Bundle using the helper shipped inside this app.
    /// Claude owns installation and presents its own extension consent screen.
    public static func build(helper: URL, directory: URL, version: String = "1.0.0") throws -> URL {
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 64 * 1024 * 1024,
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw AgentSecurity.failure("The bundled MCP helper is unavailable. Install a complete StorageDaddy build first.") }
        try AgentSecurity.preparePrivateDirectory(directory)
        let payload = directory.appendingPathComponent("payload"), server = payload.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copied = server.appendingPathComponent("storagedaddy-mcp")
        try FileManager.default.copyItem(at: helper, to: copied)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copied.path)
        let manifest: AgentJSON = .object([
            "manifest_version": .string("0.2"), "name": .string("storagedaddy"), "display_name": .string("StorageDaddy"), "version": .string(version),
            "description": .string("Read local storage scans and prepare cleanup for review in StorageDaddy."),
            "author": .object(["name": .string("StorageDaddy")]),
            "server": .object(["type": .string("binary"), "entry_point": .string("server/storagedaddy-mcp"), "mcp_config": .object(["command": .string("${__dirname}/server/storagedaddy-mcp"), "args": .array([]), "env": .object([:])])]),
            "tools_generated": .bool(true), "compatibility": .object(["platforms": .array([.string("darwin")])])
        ])
        try JSONEncoder().encode(manifest).write(to: payload.appendingPathComponent("manifest.json"))
        let destination = directory.appendingPathComponent("StorageDaddy.mcpb")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", payload.path, destination.path]
        process.standardError = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentSecurity.failure("Could not package the Claude Desktop extension.") }
        return destination
    }
}
