import Foundation

/// A locally installed agent CLI that can explain a scanned folder.
public enum FolderAgent: String, CaseIterable, Sendable {
    case claude, codex

    public var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var executableName: String { rawValue }

    /// Non-interactive arguments. Claude is pinned to read-only inspection
    /// tools; Codex runs under its read-only sandbox. Neither may modify files.
    public func arguments(prompt: String) -> [String] {
        switch self {
        case .claude:
            ["-p", prompt, "--allowedTools", "Read,Glob,Grep,LS"]
        case .codex:
            ["exec", "--sandbox", "read-only", prompt]
        }
    }
}

public struct FolderExplanationResult: Sendable {
    public let text: String
    public let elapsed: TimeInterval
}

public enum FolderExplanationError: Error, Equatable {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case timedOut
    case emptyOutput
    case cancelled
}

public enum FolderExplainer {
    public static let defaultTimeout: TimeInterval = 120
    public static let maxOutputBytes = 262_144

    /// Detects installed agent CLIs in preference order. Candidate directories
    /// cover the native installers and common package managers, then PATH.
    public static func detectAgents(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
    ) -> [(FolderAgent, URL)] {
        var directories = [
            "\(home)/.local/bin", "\(home)/.claude/local",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        if let path = environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        let ordered = directories.filter { seen.insert($0).inserted }
        return FolderAgent.allCases.compactMap { agent in
            for directory in ordered {
                let candidate = "\(directory)/\(agent.executableName)"
                if exists(candidate) { return (agent, URL(fileURLWithPath: candidate)) }
            }
            return nil
        }
    }

    /// The folder-explanation prompt shared by the copy-paste flow and the
    /// local-agent integration. Keep both paths on this one builder.
    public static func prompt(
        path: String,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        children: Int,
        modified: Date,
        assessment: FolderAssessment? = nil,
    ) -> String {
        """
        Help me understand this folder on my Mac before I change anything.

        Folder: \(path)
        storagedaddy measured:
        - Scanned allocation: \(DiskFormat.bytes(allocatedBytes))
        - Scanned logical size: \(DiskFormat.bytes(logicalBytes))
        - Observed immediate items: \(children.formatted())
        - Modified: \(modified.formatted(date: .abbreviated, time: .shortened))

        \(assessment.map { "Detected folder context (metadata inference, not proof):\n\($0.explanation)" } ?? "Folder role and scan completeness have not been confirmed.")

        Explain:
        1. What usually creates and uses this folder.
        2. Whether it is normally safe to remove or clean.
        3. What could stop working or need to be downloaded or rebuilt afterward.
        4. The safest way to reduce its size.
        5. What I should inspect before acting.

        Tailor the explanation to the detected context, but verify assumptions. If the scan is incomplete, do not treat observed bytes or item counts as the full contents, and do not describe zero scanned bytes as empty or unused. Allocated bytes do not establish reclaimable space.
        Do not delete or modify anything. If the path is app-specific or ambiguous, say what evidence would confirm it.
        """
    }

    /// Launches the agent CLI and returns a task whose `wait()` completes with
    /// the explanation. Call `wait()` off the main thread; `cancel()` is safe
    /// from any thread and terminates the child process.
    public static func start(
        agent: FolderAgent,
        executable: URL,
        prompt: String,
        timeout: TimeInterval = defaultTimeout,
        maxOutputBytes: Int = maxOutputBytes,
    ) throws -> FolderExplainTask {
        try FolderExplainTask(
            agent: agent, executable: executable, argv: agent.arguments(prompt: prompt),
            timeout: timeout, maxOutputBytes: maxOutputBytes,
        )
    }
}

public final class FolderExplainTask: @unchecked Sendable {
    public let agent: FolderAgent
    private let process = Process()
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var cancelRequested = false
    private let timeout: TimeInterval
    private let maxOutputBytes: Int
    private let group = DispatchGroup()

    init(agent: FolderAgent, executable: URL, argv: [String], timeout: TimeInterval, maxOutputBytes: Int) throws {
        self.agent = agent
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        let out = Pipe()
        let err = Pipe()
        process.executableURL = executable
        process.arguments = argv
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        group.enter()
        DispatchQueue.global().async { [weak self] in
            self?.drain(out.fileHandleForReading, into: \.outData, capped: maxOutputBytes)
            self?.group.leave()
        }
        group.enter()
        DispatchQueue.global().async { [weak self] in
            self?.drain(err.fileHandleForReading, into: \.errData, capped: 65_536)
            self?.group.leave()
        }
        do {
            try process.run()
        } catch {
            throw FolderExplanationError.launchFailed(error.localizedDescription)
        }
    }

    public func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// Blocks until the agent exits, the timeout elapses, or `cancel()` runs.
    public func wait() throws -> FolderExplanationResult {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        while process.isRunning {
            lock.lock()
            let cancelled = cancelRequested
            lock.unlock()
            if cancelled || Date() > deadline {
                process.terminate()
                let forced = Date().addingTimeInterval(2)
                while process.isRunning, Date() < forced { Thread.sleep(forTimeInterval: 0.02) }
                process.waitUntilExit()
                group.wait()
                throw cancelled ? FolderExplanationError.cancelled : .timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        group.wait()
        let elapsed = Date().timeIntervalSince(started)
        lock.lock()
        let stdout = outData
        let stderr = errData
        let cancelledAfterExit = cancelRequested
        lock.unlock()
        // terminate() can end the child before the polling loop observes the
        // request; a cancelled run is reported as cancelled either way.
        if cancelledAfterExit { throw FolderExplanationError.cancelled }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.prefix(2_048), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FolderExplanationError.nonZeroExit(process.terminationStatus, detail)
        }
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FolderExplanationError.emptyOutput }
        return FolderExplanationResult(text: text, elapsed: elapsed)
    }

    private func drain(_ handle: FileHandle, into keyPath: ReferenceWritableKeyPath<FolderExplainTask, Data>, capped limit: Int) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            lock.lock()
            let remaining = limit - self[keyPath: keyPath].count
            if remaining > 0 { self[keyPath: keyPath].append(chunk.prefix(remaining)) }
            lock.unlock()
        }
    }
}
