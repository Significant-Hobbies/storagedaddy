import Foundation
import CryptoKit

/// OAuth 2.1 public clients, dynamic registration and S256 PKCE. Authorizing a
/// browser request only queues native consent: no HTTP route grants access.
@MainActor public final class AgentOAuth {
    public struct Registration: Codable, Sendable {
        public var clientID: String
        public var clientName: String
        public var redirectURIs: [String]
        public var registeredAt: Date
    }
    private struct Authorization {
        var id: String
        var registration: Registration
        var redirect: String
        var state: String?
        var challenge: String
        var permissions: Set<String>
        var token: String
        var createdAt: Date
        var code: String?
        var codeIssuedAt: Date?
    }
    public let port: UInt16
    public var resource: String { "http://127.0.0.1:\(port)/mcp" }
    private var issuer: String { "http://127.0.0.1:\(port)" }
    private var registrations: [String: Registration] = [:]
    private var authorizations: [String: Authorization] = [:]
    private var activeTokenHashes: Set<String> = []
    private let onPair: @MainActor @Sendable (String, String, Set<String>, String, String) -> Void
    private let status: @MainActor @Sendable (String) -> String
    private let permissions: @MainActor @Sendable (String) -> Set<String>
    private let rpc: @MainActor @Sendable (String, AgentJSON) async -> AgentJSON
    private let saveRegistration: @MainActor @Sendable (Registration) -> Void

    public init(port: UInt16 = 51736, registrations: [Registration] = [],
                onPair: @escaping @MainActor @Sendable (String, String, Set<String>, String, String) -> Void,
                status: @escaping @MainActor @Sendable (String) -> String,
                permissions: @escaping @MainActor @Sendable (String) -> Set<String>,
                saveRegistration: @escaping @MainActor @Sendable (Registration) -> Void,
                rpc: @escaping @MainActor @Sendable (String, AgentJSON) async -> AgentJSON) {
        self.port = port; self.registrations = Dictionary(registrations.prefix(100).map { ($0.clientID, $0) }, uniquingKeysWith: { first, _ in first })
        self.onPair = onPair; self.status = status; self.permissions = permissions; self.rpc = rpc; self.saveRegistration = saveRegistration
    }
    public func resetPending() { authorizations.removeAll(); activeTokenHashes.removeAll() }

    public func forgetRegistrations(_ clientIDs: Set<String>) {
        registrations = registrations.filter { !clientIDs.contains($0.key) }
        authorizations = authorizations.filter { !clientIDs.contains($0.value.registration.clientID) }
    }

    public func handle(_ request: AgentHTTPRequest) async -> AgentHTTPResponse {
        do { try AgentHTTPServer.validateHeaders(request.headers, port: port) }
        catch { return .failure("invalid_request", status: 400) }
        guard let url = URLComponents(string: issuer + request.target) else { return .failure("invalid_request", status: 400) }
        authorizations = authorizations.filter { Date().timeIntervalSince($0.value.createdAt) < 600 }
        switch (request.method, url.path) {
        case ("GET", "/.well-known/oauth-authorization-server"):
            return .json(.object(["issuer": .string(issuer), "authorization_endpoint": .string(issuer + "/authorize"), "token_endpoint": .string(issuer + "/token"), "registration_endpoint": .string(issuer + "/register"),
                                  "response_types_supported": .array([.string("code")]), "grant_types_supported": .array([.string("authorization_code")]), "token_endpoint_auth_methods_supported": .array([.string("none")]),
                                  "code_challenge_methods_supported": .array([.string("S256")]), "scopes_supported": .array(AgentRole.admin.permissions.sorted().map(AgentJSON.string))]))
        case ("GET", "/.well-known/oauth-protected-resource/mcp"), ("GET", "/.well-known/oauth-protected-resource"):
            return .json(.object(["resource": .string(resource), "authorization_servers": .array([.string(issuer)]), "scopes_supported": .array(AgentRole.admin.permissions.sorted().map(AgentJSON.string)), "bearer_methods_supported": .array([.string("header")])]))
        case ("POST", "/register"): return register(request)
        case ("GET", "/authorize"): return authorize(url)
        case ("GET", "/authorization-result"): return authorizationResult(url)
        case ("POST", "/token"): return token(request)
        case ("POST", "/mcp"):
            guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { return .failure("unsupported_media_type", status: 415) }
            guard let header = request.headers["authorization"], header.hasPrefix("Bearer "), header.count <= 107 else { return unauthorized() }
            let token = String(header.dropFirst(7))
            let hash = AgentSecurity.hash(token)
            guard activeTokenHashes.contains(hash), status(hash) == "approved" else { return unauthorized() }
            guard let json = try? JSONDecoder().decode(AgentJSON.self, from: request.body), json.object != nil else { return .json(AgentMCP.error(id: .null, code: -32700, message: "Invalid JSON-RPC request."), status: 400) }
            let response = await rpc(token, json)
            if response["state"].string == "unauthorized" { return unauthorized() }
            return response == .null ? .init(status: 202) : .json(response)
        case (_, "/mcp"): return .failure("method_not_allowed", status: 405)
        default: return .failure("not_found", status: 404)
        }
    }
    private func unauthorized() -> AgentHTTPResponse {
        .json(.object(["error": .string("unauthorized")]), status: 401, headers: ["WWW-Authenticate": "Bearer resource_metadata=\"\(issuer)/.well-known/oauth-protected-resource/mcp\""])
    }
    private func register(_ request: AgentHTTPRequest) -> AgentHTTPResponse {
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
              request.body.count <= 16384, let input = try? JSONDecoder().decode(AgentJSON.self, from: request.body),
              let redirects = input["redirect_uris"].array, !redirects.isEmpty, redirects.count <= 8,
              redirects.allSatisfy({ $0.string.map(Self.validRedirect) == true }),
              input["token_endpoint_auth_method"].string == nil || input["token_endpoint_auth_method"].string == "none",
              input["grant_types"].array == nil || input["grant_types"].array == [.string("authorization_code")],
              registrations.count < 100 else { return .failure("invalid_client_metadata", status: 400) }
        do {
            let id = try AgentSecurity.randomToken(), name = String((input["client_name"].string ?? "HTTP MCP client").prefix(100))
            let uris = redirects.compactMap(\.string)
            registrations[id] = Registration(clientID: id, clientName: name, redirectURIs: uris, registeredAt: Date())
            return .json(.object(["client_id": .string(id), "client_id_issued_at": .integer(Int(Date().timeIntervalSince1970)), "client_name": .string(name), "redirect_uris": .array(uris.map(AgentJSON.string)),
                                  "grant_types": .array([.string("authorization_code")]), "response_types": .array([.string("code")]), "token_endpoint_auth_method": .string("none")]), status: 201)
        } catch { return .failure("server_error", status: 500) }
    }
    private func authorize(_ url: URLComponents) -> AgentHTTPResponse {
        guard let p = Self.parameters(url.queryItems), p["response_type"] == "code", p["code_challenge_method"] == "S256", p["resource"] == resource,
              let client = p["client_id"], let registration = registrations[client], let redirect = p["redirect_uri"], registration.redirectURIs.contains(redirect),
              let challenge = p["code_challenge"], challenge.count == 43, challenge.allSatisfy(Self.pkceCharacter),
              (p["state"]?.utf8.count ?? 0) <= 2048, authorizations.count < 20 else { return .failure("invalid_request", status: 400) }
        let requested = Set((p["scope"] ?? "read scan navigate").split(separator: " ").map(String.init))
        guard !requested.isEmpty, requested.isSubset(of: AgentRole.admin.permissions) else { return .failure("invalid_scope", status: 400) }
        do {
            let id = try AgentSecurity.randomToken(), token = try AgentSecurity.randomToken(), nonce = try AgentSecurity.randomToken()
            authorizations[id] = Authorization(id: id, registration: registration, redirect: redirect, state: p["state"], challenge: challenge, permissions: requested, token: token, createdAt: Date())
            onPair(registration.clientName, AgentSecurity.hash(token), requested, redirect, registration.clientID)
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Continue in StorageDaddy</title></head>
            <body style="background:#090d0b;color:#e3f8ec;font:17px system-ui;max-width:38rem;margin:15vh auto;padding:24px"><h1>Continue in StorageDaddy</h1><p>Open AI Agents in StorageDaddy and review the waiting request. Only the app can approve access.</p><p id="status">Waiting for your decision…</p>
            <script nonce="\(nonce)">async function poll(){try{const r=await fetch('/authorization-result?id=\(id)',{cache:'no-store'});const v=await r.json();if(v.redirect){location.replace(v.redirect);return;}if(v.error){document.getElementById('status').textContent='This request expired. Reconnect your client to try again.';return;}}catch{}setTimeout(poll,1000);}poll();</script></body></html>
            """
            return .init(headers: ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"], body: Data(html.utf8))
        } catch { return .failure("server_error", status: 500) }
    }
    private func authorizationResult(_ url: URLComponents) -> AgentHTTPResponse {
        guard let p = Self.parameters(url.queryItems), let id = p["id"], var auth = authorizations[id] else { return .failure("expired_request", status: 400) }
        let state = status(AgentSecurity.hash(auth.token))
        if state == "denied" || state == "revoked" {
            authorizations.removeValue(forKey: id)
            return .json(.object(["redirect": .string(redirect(auth, result: ["error": "access_denied"]))]))
        }
        guard state == "approved" else { return .json(.object(["state": .string("pending")])) }
        if auth.code == nil {
            guard let code = try? AgentSecurity.randomToken() else { return .failure("server_error", status: 500) }
            auth.code = code; auth.codeIssuedAt = Date(); authorizations[id] = auth
            saveRegistration(auth.registration)
        }
        return .json(.object(["redirect": .string(redirect(auth, result: ["code": auth.code!]))]))
    }
    private func token(_ request: AgentHTTPRequest) -> AgentHTTPResponse {
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/x-www-form-urlencoded", request.body.count <= 16384,
              let body = String(data: request.body, encoding: .utf8), let p = Self.form(body), p["grant_type"] == "authorization_code", p["resource"] == resource,
              let code = p["code"], let found = authorizations.first(where: { $0.value.code == code }),
              let issued = found.value.codeIssuedAt, Date().timeIntervalSince(issued) < 120,
              p["client_id"] == found.value.registration.clientID, p["redirect_uri"] == found.value.redirect,
              let verifier = p["code_verifier"], (43...128).contains(verifier.count), verifier.allSatisfy(Self.pkceCharacter),
              Self.challenge(verifier) == found.value.challenge, status(AgentSecurity.hash(found.value.token)) == "approved" else { return .failure("invalid_grant", status: 400) }
        authorizations.removeValue(forKey: found.key)
        // HTTP has no OS-account-bound server identity. A different account can
        // bind the port while this app is off. Previously harvested bearers
        // must never become valid in a later listener lifetime.
        activeTokenHashes.insert(AgentSecurity.hash(found.value.token))
        let scopes = permissions(AgentSecurity.hash(found.value.token)).intersection(found.value.permissions)
        return .json(.object(["access_token": .string(found.value.token), "token_type": .string("Bearer"), "scope": .string(scopes.sorted().joined(separator: " "))]))
    }
    private func redirect(_ authorization: Authorization, result: [String: String]) -> String {
        var url = URLComponents(string: authorization.redirect)!
        var items = url.queryItems ?? []
        items.append(contentsOf: result.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) })
        if let state = authorization.state { items.append(URLQueryItem(name: "state", value: state)) }
        url.queryItems = items
        return url.string!
    }
    nonisolated public static func validRedirect(_ value: String) -> Bool {
        guard value.count <= 4096, !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }), let url = URLComponents(string: value), url.scheme == "http", url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host, ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host), let port = url.port, (1...65535).contains(port) else { return false }
        return true
    }
    nonisolated public static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    nonisolated private static func pkceCharacter(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber || "-._~".contains(character)) }
    private static func parameters(_ items: [URLQueryItem]?) -> [String: String]? {
        var result: [String: String] = [:]
        for item in items ?? [] { guard result[item.name] == nil, let value = item.value else { return nil }; result[item.name] = value }
        return result
    }
    private static func form(_ body: String) -> [String: String]? {
        var result: [String: String] = [:]
        for field in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !name.isEmpty, result[name] == nil else { return nil }
            result[name] = value
        }
        return result
    }
}
