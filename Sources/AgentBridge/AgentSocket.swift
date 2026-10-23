import Foundation
import Darwin

/// A private Unix socket avoids browser origins, DNS rebinding and impersonation
/// by another OS account. Every accepted peer is checked before any bytes are read.
public final class AgentSocketServer: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var active = 0
    private var path: String?
    private var identity: (dev_t, ino_t)?
    public init() {}
    deinit { stop() }

    public func start(path: String, handler: @escaping @Sendable (AgentBridgeRequest) async -> AgentJSON) throws {
        guard lock.withLock({ descriptor < 0 }) else { return }
        let url = URL(fileURLWithPath: path)
        try AgentSecurity.preparePrivateDirectory(url.deletingLastPathComponent())
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw AgentSecurity.failure("An unsafe item occupies the agent socket location.") }
            if let connected = try? AgentSocketClient.connect(path: path) { close(connected); throw AgentSecurity.failure("Another StorageDaddy instance is listening.") }
            guard unlink(path) == 0 else { throw AgentSecurity.failure("Cannot replace the stale agent socket.") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSecurity.failure("Cannot create the local agent listener.") }
        var success = false
        defer { if !success { close(fd) } }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = try AgentSocketClient.address(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw AgentSecurity.failure("Cannot bind the local agent listener.") }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0, lstat(path, &info) == 0 else {
            unlink(path); throw AgentSecurity.failure("Cannot protect the local agent listener.")
        }
        lock.withLock { descriptor = fd; self.path = path; identity = (info.st_dev, info.st_ino) }
        success = true
        DispatchQueue(label: "StorageDaddy.agent.accept", qos: .utility).async { [weak self] in
            while let self, self.lock.withLock({ self.descriptor == fd }) {
                let peer = accept(fd, nil, nil)
                if peer < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var uid: uid_t = 0, gid: gid_t = 0
                let allowed = getpeereid(peer, &uid, &gid) == 0 && uid == getuid() && self.lock.withLock {
                    guard self.active < 16, self.descriptor == fd else { return false }
                    self.active += 1; return true
                }
                guard allowed else { close(peer); continue }
                AgentSocketClient.protect(peer)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    do {
                        let request = try JSONDecoder().decode(AgentBridgeRequest.self, from: AgentSocketClient.readLine(peer))
                        Task {
                            let response = await handler(request)
                            try? AgentSocketClient.writeLine(JSONEncoder().encode(response), to: peer)
                            close(peer)
                            self?.lock.withLock { self?.active -= 1 }
                        }
                    } catch {
                        close(peer)
                        self?.lock.withLock { self?.active -= 1 }
                    }
                }
            }
        }
    }

    public func stop() {
        let old: (Int32, String?, (dev_t, ino_t)?) = lock.withLock {
            let old = (descriptor, path, identity); descriptor = -1; path = nil; identity = nil; return old
        }
        guard old.0 >= 0 else { return }
        shutdown(old.0, SHUT_RDWR); close(old.0)
        if let path = old.1, let identity = old.2 {
            var info = stat()
            if lstat(path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { unlink(path) }
        }
    }
}

public enum AgentSocketClient {
    public static let maximumMessageBytes = 1024 * 1024
    public static func request(_ request: AgentBridgeRequest, path: String = AgentSecurity.socketPath) throws -> AgentJSON {
        let fd = try connect(path: path); defer { close(fd) }
        try writeLine(JSONEncoder().encode(request), to: fd)
        return try JSONDecoder().decode(AgentJSON.self, from: readLine(fd))
    }

    static func connect(path: String) throws -> Int32 {
        try AgentSecurity.preparePrivateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw AgentSecurity.failure("Open StorageDaddy and enable AI Agents to connect.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSecurity.failure("Cannot open the local agent connection.") }
        protect(fd)
        do {
            var address = try address(path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw AgentSecurity.failure("Open StorageDaddy and enable AI Agents to connect.") }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AgentSecurity.failure("The listener belongs to another account.") }
            return fd
        } catch { close(fd); throw error }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var result = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: result.sun_path) else { throw AgentSecurity.failure("The agent socket path is too long.") }
        result.sun_family = sa_family_t(AF_UNIX)
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &result.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: path.utf8)
        }
        return result
    }

    static func protect(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    static func readLine(_ fd: Int32) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumMessageBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumMessageBytes + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentSecurity.failure("Agent connection closed or timed out.") }
            if let newline = buffer.prefix(count).firstIndex(of: 10) {
                guard newline == count - 1 else { throw AgentSecurity.failure("Only one message per local connection is allowed.") }
                data.append(contentsOf: buffer.prefix(newline))
                guard data.count <= maximumMessageBytes else { break }
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw AgentSecurity.failure("Agent message exceeds the 1 MiB limit.")
    }

    static func writeLine(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumMessageBytes else { throw AgentSecurity.failure("Agent response exceeds the 1 MiB limit. Use pagination.") }
        var message = data; message.append(10)
        try message.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentSecurity.failure("Cannot write to the agent connection.") }
                offset += count
            }
        }
    }
}
