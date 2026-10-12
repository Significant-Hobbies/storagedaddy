import Darwin
import Foundation

/// Positive evidence of current use, including working directories and mapped
/// files. Absence of an open handle is not proof that a folder is never needed.
enum CleanupActiveUse {
    static func validate(urls: [URL]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-F0pcn", "-u", String(getuid())]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw error("Current file use could not be checked. Quit active builds or installs and review this folder again.")
        }
        for url in urls {
            if let user = user(of: url.path, in: text) {
                throw error("\(url.lastPathComponent) is in use by \(user). Quit that process before cleanup.")
            }
        }
    }

    static func user(of path: String, in output: String) -> String? {
        let root = CleanupGuidance.normalized(path)
        var pid = "", command = "a running process"
        for field in output.split(separator: "\0") {
            let field = field.trimmingCharacters(in: .newlines)
            guard let type = field.first else { continue }
            let value = String(field.dropFirst())
            switch type {
            case "p": pid = value; command = "a running process"
            case "c": command = value
            case "n":
                guard value.hasPrefix("/") else { continue }
                let file = CleanupGuidance.normalized(value)
                if file == root || file.hasPrefix(root + "/") { return "\(command) (PID \(pid))" }
            default: break
            }
        }
        return nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CleanupActiveUse", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
