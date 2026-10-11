import Darwin
import Foundation

public enum ChromeSigningClones {
    public enum Location: Sendable { case store, copy, contents }

    public static let explanation = "Chrome creates temporary app copies at startup so its code-signature checks keep working while updates are staged. APFS copies share blocks with Chrome and other copies; their logical sizes do not add up to physical storage. These are app binaries, separate from your browser profile and browsing history."
    public static let cleanupExplanation = "Quit every Chrome window and background process first. Review whole signing copies older than 24 hours; keep recent or unverified copies. Each copy is checked again before it moves to Trash. Shared blocks may remain in Chrome, other copies or snapshots, so recovered space can be small."

    public static func location(path: String) -> Location? {
        var path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path.hasPrefix("/System/Volumes/Data/") { path.removeFirst("/System/Volumes/Data".count) }
        if path.hasPrefix("/var/folders/") { path = "/private" + path }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 7, Array(parts.prefix(3)) == ["private", "var", "folders"],
              parts[5] == "X", parts[6] == "com.google.Chrome.code_sign_clone" else { return nil }
        if parts.count == 7 { return .store }
        guard isCopyName(parts[7]) else { return .contents }
        return parts.count == 8 ? .copy : .contents
    }

    public static func isCopyName(_ name: String) -> Bool {
        let prefix = "code_sign_clone."
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.utf8.count == 6 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    public static func copyIDs(in scan: ScanResult, storeID: Int) -> [Int] {
        guard scan.nodes.indices.contains(storeID), location(path: scan.url(for: storeID).path) == .store else { return [] }
        return scan.nodes[storeID].children.filter {
            scan.nodes.indices.contains($0) && scan.nodes[$0].isDirectory && !scan.nodes[$0].isSymlink && isCopyName(scan.nodes[$0].name)
        }
    }

    public static func validateForCleanup(at url: URL) throws {
        switch location(path: url.path) {
        case .store:
            throw failure("Review individual signing copies instead of moving the entire Chrome signing-copy store.")
        case .contents:
            throw failure("Review the whole signing copy. Removing individual binaries can break code-signature checks.")
        case .copy:
            try validateCopy(at: url, now: Date(), chromeIsRunning: chromeIsRunning)
        case nil: break
        }
    }

    // Separate filesystem validation lets tests exercise active/recent/changed
    // copies without creating anything in the user's real signing-copy store.
    static func validateCopy(at url: URL, now: Date, chromeIsRunning: () throws -> Bool) throws {
        guard try !chromeIsRunning() else { throw failure("Quit Chrome and its background processes before reviewing signing-copy cleanup.") }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure("The signing copy is missing or is a symbolic link. Rescan before cleanup.") }
        guard now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= 24 * 3600 else {
            throw failure("Keep signing copies modified within the last 24 hours. Review this copy later.")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard names.count == 1, ["Google Chrome.app.bundle", "Google Chrome.app"].contains(names[0]) else {
            throw failure("The signing copy has an unexpected structure. Inspect its contents instead of using signing-copy cleanup.")
        }
        let versions = url.appendingPathComponent(names[0]).appendingPathComponent("Contents/Frameworks/Google Chrome Framework.framework/Versions")
        let entries = try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
        var checked = 0
        for version in entries where version.lastPathComponent != "Current" {
            var versionInfo = stat()
            guard lstat(version.path, &versionInfo) == 0, versionInfo.st_mode & S_IFMT == S_IFDIR else {
                throw failure("The signing copy's framework versions could not be verified.")
            }
            let binary = version.appendingPathComponent("Google Chrome Framework")
            guard let physical = realpath(binary.path, nil) else { throw failure("The signing copy's framework is missing.") }
            let physicalPath = String(cString: physical); free(physical)
            guard physicalPath == binary.path else { throw failure("The signing copy's framework traverses a symbolic link.") }
            let descriptor = open(binary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw failure("The signing copy's framework could not be checked for current use.") }
            defer { close(descriptor) }
            var binaryInfo = stat()
            guard fstat(descriptor, &binaryInfo) == 0, binaryInfo.st_mode & S_IFMT == S_IFREG else {
                throw failure("The signing copy's framework is not a regular file.")
            }
            var state: UInt32 = 0
            // FSIOC_FD_ONLY_OPEN_ONCE from XNU; also used by Chromium.
            guard ffsctl(descriptor, UInt(0xC0044115), &state, 0) == 0 else {
                throw failure("The signing copy may still be in use, or its use could not be verified. Keep it and review again after quitting Chrome.")
            }
            checked += 1
        }
        guard checked > 0 else { throw failure("No framework version could be verified in this signing copy.") }
    }

    private static func chromeIsRunning() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Executable paths only; never collect browser URLs or profile arguments.
        process.arguments = ["-axo", "comm="]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw failure("Chrome's running processes could not be verified. Nothing will move.")
        }
        return text.split(separator: "\n").contains { $0.contains("/Google Chrome.app/") || $0.contains("/Google Chrome.app.bundle/") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ChromeSigningCopies", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
