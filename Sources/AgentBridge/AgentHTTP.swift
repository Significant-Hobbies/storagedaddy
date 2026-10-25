import Foundation
import Darwin

public struct AgentHTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
    public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.target = target; self.headers = headers; self.body = body
    }
}
public struct AgentHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) { self.status = status; self.headers = headers; self.body = body }
    public static func json(_ json: AgentJSON, status: Int = 200, headers: [String: String] = [:]) -> AgentHTTPResponse {
        var headers = headers; headers["Content-Type"] = "application/json"
        return .init(status: status, headers: headers, body: (try? JSONEncoder().encode(json)) ?? Data())
    }
    public static func failure(_ error: String, status: Int) -> AgentHTTPResponse { .json(.object(["error": .string(error)]), status: status) }
}

/// Minimal one-request HTTP/1.1 listener. No transfer encoding, pipelining,
/// cookies, credentialed CORS, external interfaces or broad filesystem routes.
public final class AgentHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var active = 0
    public init() {}
    deinit { stop() }
    public func start(port: UInt16, handler: @escaping @Sendable (AgentHTTPRequest) async -> AgentHTTPResponse) throws {
        guard lock.withLock({ fd < 0 }) else { return }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AgentSecurity.failure("Cannot create HTTP agent listener.") }
        var success = false
        defer { if !success { close(listener) } }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 16) == 0 else { throw AgentSecurity.failure("Port \(port) is unavailable. Quit the other listener before enabling AI Agents.") }
        lock.withLock { fd = listener }; success = true
        DispatchQueue(label: "StorageDaddy.agent.http", qos: .utility).async { [weak self] in
            while let self, self.lock.withLock({ self.fd == listener }) {
                var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let peer = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) } }
                if peer < 0 { if errno == EINTR { continue }; break }
                let allowed = address.sin_family == AF_INET && address.sin_addr.s_addr == inet_addr("127.0.0.1") && self.lock.withLock {
                    guard self.fd == listener, self.active < 16 else { return false }; self.active += 1; return true
                }
                guard allowed else { close(peer); continue }
                AgentSocketClient.protect(peer)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    do {
                        let request = try Self.read(peer, port: port)
                        Task {
                            let response = await handler(request)
                            try? Self.write(response, fd: peer)
                            close(peer); self?.lock.withLock { self?.active -= 1 }
                        }
                    } catch {
                        try? Self.write(.failure("invalid_request", status: 400), fd: peer)
                        close(peer); self?.lock.withLock { self?.active -= 1 }
                    }
                }
            }
        }
    }
    public func stop() {
        let old = lock.withLock { let value = fd; fd = -1; return value }
        if old >= 0 { shutdown(old, SHUT_RDWR); close(old) }
    }

    public static func validateHeaders(_ headers: [String: String], port: UInt16) throws {
        let host = "127.0.0.1:\(port)"
        guard headers["host"] == host, headers["transfer-encoding"] == nil,
              headers["origin"] == nil || headers["origin"] == "http://" + host else { throw AgentSecurity.failure("Host or browser origin refused.") }
    }
    private static func read(_ fd: Int32, port: UInt16) throws -> AgentHTTPRequest {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let delimiter = Data([13, 10, 13, 10])
        while data.range(of: delimiter) == nil {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentSecurity.failure("Incomplete HTTP headers.") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= AgentSocketClient.maximumMessageBytes + 16384 else { throw AgentSecurity.failure("HTTP request too large.") }
            if data.range(of: delimiter) == nil && data.count > 16384 { throw AgentSecurity.failure("HTTP headers too large.") }
        }
        guard let range = data.range(of: delimiter), range.lowerBound <= 16384,
              let header = String(data: data.prefix(upTo: range.lowerBound), encoding: .utf8) else { throw AgentSecurity.failure("Invalid HTTP headers.") }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST", "DELETE", "OPTIONS"].contains(first[0]), first[1].hasPrefix("/"), !first[1].hasPrefix("//"), first[1].count <= 8192,
              first[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw AgentSecurity.failure("Invalid HTTP request line.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw AgentSecurity.failure("Invalid HTTP header.") }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil,
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else { throw AgentSecurity.failure("Invalid or duplicate HTTP header.") }
            headers[key] = value
        }
        try validateHeaders(headers, port: port)
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy(\.isNumber), let length = Int(rawLength), length <= AgentSocketClient.maximumMessageBytes else { throw AgentSecurity.failure("Invalid HTTP content length.") }
        var body = Data(data.suffix(from: range.upperBound))
        guard body.count <= length else { throw AgentSecurity.failure("HTTP pipelining is refused.") }
        while body.count < length {
            let count = Darwin.read(fd, &buffer, min(buffer.count, length - body.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentSecurity.failure("Incomplete HTTP body.") }
            body.append(contentsOf: buffer.prefix(count))
        }
        return .init(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
    private static func write(_ response: AgentHTTPResponse, fd: Int32) throws {
        guard response.body.count <= AgentSocketClient.maximumMessageBytes else { throw AgentSecurity.failure("HTTP response too large.") }
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count); headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"; headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        var text = "HTTP/1.1 \(response.status) \(response.status < 400 ? "OK" : "Error")\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { throw AgentSecurity.failure("Invalid HTTP response header.") }
            text += key + ": " + value + "\r\n"
        }
        var data = Data((text + "\r\n").utf8); data.append(response.body)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentSecurity.failure("HTTP connection closed.") }
                offset += count
            }
        }
    }
}
