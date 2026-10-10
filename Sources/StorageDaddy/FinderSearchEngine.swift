// Transport adapted from FinderSearch Engine.swift (MIT, zeusinsight, 2026).
// See Vendor/FinderSearch/LICENSE. The child only searches supplied scan metadata.
import Foundation
import Darwin
import DiskCore

struct FilenameSearchHit: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let score: Int
}
struct FilenameSearchReply: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let hits: [FilenameSearchHit]?
    let took_us: UInt64?
}

final class FinderSearchEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StorageDaddy.filename-search", qos: .userInitiated)
    private let binary: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var loaded: UUID?

    init(binary: URL? = nil) {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-search")
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/FinderSearchSupport/storage-search")
        self.binary = binary ?? (Bundle.main.bundleURL.pathExtension == "app" ? bundled : local)
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }
    private struct SearchNode: Encodable {
        let id: Int
        let parent: Int?
        let name: String
        let kind: Int
        let size: UInt64
        let mtime: UInt32
        init(_ n: DiskNode) {
            id = n.id; parent = n.parent; name = n.name
            kind = n.isSymlink ? 2 : n.isDirectory ? 1 : 0
            size = UInt64(max(0, n.logicalBytes))
            mtime = UInt32(clamping: Int64(max(0, min(Double(UInt32.max), n.modified.timeIntervalSince1970))))
        }
    }
    private struct Load: Encodable { let op = "load"; let root: String; let nodes: [SearchNode] }
    private struct Search: Encodable { let op = "search"; let q: String; let scope: Int }

    func search(scan: ScanResult, identity: UUID, query: String, scope: Int) async throws -> FilenameSearchReply {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        try self.connect()
                        if self.loaded != identity {
                            let load = Load(root: scan.rootPath, nodes: scan.nodes.map(SearchNode.init))
                            _ = try self.exchange(load, cancellation: cancellation)
                            self.loaded = identity
                        }
                        let reply = try self.exchange(Search(q: query, scope: scope), cancellation: cancellation)
                        try cancellation.check()
                        continuation.resume(returning: reply)
                    } catch {
                        self.disconnect()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func connect() throws {
        if process?.isRunning == true { return }
        disconnect()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure(message: "Filename search helper is missing. Build and package StorageDaddy with scripts/prepare-finder-search.py --build.")
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = binary
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    private func exchange<T: Encodable>(_ request: T, cancellation: Cancellation) throws -> FilenameSearchReply {
        try cancellation.check()
        guard let input, let output else { throw Failure(message: "Filename search disconnected.") }
        try input.write(contentsOf: JSONEncoder().encode(request) + Data([10]))
        let deadline = Date().addingTimeInterval(120)
        while !buffer.contains(10) {
            try cancellation.check()
            guard Date() < deadline else { throw Failure(message: "Filename search timed out. Try again.") }
            var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw Failure(message: "Could not read filename search results.") }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw Failure(message: "Filename search stopped. Try again.") }
            buffer.append(chunk)
        }
        try cancellation.check()
        let newline = buffer.firstIndex(of: 10)!
        let line = buffer.prefix(upTo: newline)
        let reply = try JSONDecoder().decode(FilenameSearchReply.self, from: line)
        buffer.removeSubrange(...newline)
        guard reply.ok else { throw Failure(message: reply.error ?? "Filename search failed.") }
        return reply
    }
    private func disconnect() {
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        try? output?.close()
        process = nil; input = nil; output = nil; loaded = nil; buffer.removeAll()
    }
    deinit { disconnect() }
}
