import XCTest
import Foundation
@testable import AgentBridge

@MainActor private final class NativeConsent {
    var hash: String?
    var requested: Set<String> = []
    var state = "pending"
    var saved = 0
}

final class AgentOAuthTests: XCTestCase {
    @MainActor func testPKCERegistrationNativeApprovalTokenReplayAndRevocation() async throws {
        let consent = NativeConsent()
        let oauth = AgentOAuth(onPair: { _, hash, scopes, _, _ in consent.hash = hash; consent.requested = scopes }, status: { hash in hash == consent.hash ? consent.state : "unknown" }, permissions: { _ in AgentRole.guide.permissions }, saveRegistration: { _ in consent.saved += 1 }, rpc: { _, request in AgentMCP.result(id: request["id"], .object(["approved": .bool(true)])) })
        func request(_ method: String, _ target: String, _ body: Data = Data(), _ type: String? = nil, token: String? = nil) -> AgentHTTPRequest {
            var headers = ["host": "127.0.0.1:51736"]
            if let type { headers["content-type"] = type }
            if let token { headers["authorization"] = "Bearer " + token }
            return .init(method: method, target: target, headers: headers, body: body)
        }
        let metadata = try JSONEncoder().encode(AgentJSON.object(["client_name": .string("Fixture Codex"), "redirect_uris": .array([.string("http://127.0.0.1:56321/callback")]), "token_endpoint_auth_method": .string("none")]))
        let registered = await oauth.handle(request("POST", "/register", metadata, "application/json"))
        XCTAssertEqual(registered.status, 201)
        let client = try JSONDecoder().decode(AgentJSON.self, from: registered.body)["client_id"].string!
        let verifier = String(repeating: "v", count: 64)
        var url = URLComponents()
        url.path = "/authorize"
        url.queryItems = ["client_id": client, "redirect_uri": "http://127.0.0.1:56321/callback", "response_type": "code", "code_challenge": AgentOAuth.challenge(verifier), "code_challenge_method": "S256", "resource": oauth.resource, "scope": "read scan navigate", "state": "client-state"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let authorized = await oauth.handle(request("GET", url.string!))
        XCTAssertEqual(authorized.status, 200)
        XCTAssertEqual(consent.state, "pending")
        let html = String(data: authorized.body, encoding: .utf8)!
        let id = html.components(separatedBy: "/authorization-result?id=")[1].components(separatedBy: "'")[0]
        let waiting = await oauth.handle(request("GET", "/authorization-result?id=" + id))
        XCTAssertEqual(try JSONDecoder().decode(AgentJSON.self, from: waiting.body)["state"].string, "pending")
        XCTAssertEqual(consent.requested, AgentRole.guide.permissions)
        consent.state = "approved" // Only native code changes this state.
        let ready = await oauth.handle(request("GET", "/authorization-result?id=" + id))
        let redirect = try JSONDecoder().decode(AgentJSON.self, from: ready.body)["redirect"].string!
        let callback = URLComponents(string: redirect)!
        let code = callback.queryItems!.first(where: { $0.name == "code" })!.value!
        XCTAssertEqual(callback.queryItems!.first(where: { $0.name == "state" })!.value, "client-state")
        XCTAssertEqual(consent.saved, 1)
        func tokenBody(_ verifier: String) -> Data {
            var c = URLComponents()
            c.queryItems = ["grant_type": "authorization_code", "code": code, "client_id": client, "redirect_uri": "http://127.0.0.1:56321/callback", "resource": oauth.resource, "code_verifier": verifier].map { URLQueryItem(name: $0.key, value: $0.value) }
            return Data(c.percentEncodedQuery!.utf8)
        }
        let wrong = await oauth.handle(request("POST", "/token", tokenBody(String(repeating: "x", count: 64)), "application/x-www-form-urlencoded"))
        XCTAssertEqual(wrong.status, 400)
        let exchanged = await oauth.handle(request("POST", "/token", tokenBody(verifier), "application/x-www-form-urlencoded"))
        XCTAssertEqual(exchanged.status, 200)
        let token = try JSONDecoder().decode(AgentJSON.self, from: exchanged.body)["access_token"].string!
        XCTAssertEqual(AgentSecurity.hash(token), consent.hash)
        let replay = await oauth.handle(request("POST", "/token", tokenBody(verifier), "application/x-www-form-urlencoded"))
        XCTAssertEqual(replay.status, 400)
        let call = try JSONEncoder().encode(AgentJSON.object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("ping")]))
        let mcp = await oauth.handle(request("POST", "/mcp", call, "application/json", token: token))
        XCTAssertEqual(mcp.status, 200)
        oauth.resetPending()
        let previousListenerToken = await oauth.handle(request("POST", "/mcp", call, "application/json", token: token))
        XCTAssertEqual(previousListenerToken.status, 401)
        consent.state = "revoked"
        let revoked = await oauth.handle(request("POST", "/mcp", call, "application/json", token: token))
        XCTAssertEqual(revoked.status, 401)
        XCTAssertTrue(revoked.headers["WWW-Authenticate"]!.contains("oauth-protected-resource/mcp"))
    }

    func testOriginHostAndRedirectBoundaries() throws {
        XCTAssertNoThrow(try AgentHTTPServer.validateHeaders(["host": "127.0.0.1:51736"], port: 51736))
        XCTAssertNoThrow(try AgentHTTPServer.validateHeaders(["host": "127.0.0.1:51736", "origin": "http://127.0.0.1:51736"], port: 51736))
        for headers in [["host": "attacker.example:51736"], ["host": "127.0.0.1:51736", "origin": "https://attacker.example"], ["host": "127.0.0.1:51736", "origin": "null"], ["host": "127.0.0.1:51736", "transfer-encoding": "chunked"]] {
            XCTAssertThrowsError(try AgentHTTPServer.validateHeaders(headers, port: 51736))
        }
        for uri in ["https://example.com/callback", "http://127.0.0.1/callback", "http://127.0.0.1:1234/callback#fragment", "http://user@localhost:1234/callback", "http://localhost.attacker.example:1234/callback", "file:///tmp/callback"] { XCTAssertFalse(AgentOAuth.validRedirect(uri)) }
        for uri in ["http://127.0.0.1:1234/callback", "http://localhost:1234/callback", "http://[::1]:1234/callback"] { XCTAssertTrue(AgentOAuth.validRedirect(uri)) }
    }

    @MainActor func testBrowserCannotApproveAndBadResourceIsRefused() async throws {
        let consent = NativeConsent()
        let oauth = AgentOAuth(onPair: { _, hash, _, _, _ in consent.hash = hash }, status: { _ in "pending" }, permissions: { _ in [] }, saveRegistration: { _ in }, rpc: { _, _ in .null })
        let approval = await oauth.handle(.init(method: "POST", target: "/approve", headers: ["host": "127.0.0.1:51736"]))
        XCTAssertEqual(approval.status, 404)
        XCTAssertNil(consent.hash)
        let arbitrary = await oauth.handle(.init(method: "GET", target: "/authorize?response_type=code&resource=http%3A%2F%2Fevil.example", headers: ["host": "127.0.0.1:51736"]))
        XCTAssertEqual(arbitrary.status, 400)
        let malformed = await oauth.handle(.init(method: "POST", target: "/token", headers: ["host": "127.0.0.1:51736", "content-type": "application/x-www-form-urlencoded"], body: Data("code=%ZZ&grant_type=authorization_code".utf8)))
        XCTAssertEqual(malformed.status, 400)
    }

    func testRealLoopbackHTTPRoundTrip() async throws {
        let server = AgentHTTPServer()
        let port = UInt16.random(in: 55000...60000)
        try server.start(port: port) { request in .json(.object(["target": .string(request.target)])) }
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/fixture")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(AgentJSON.self, from: data)["target"].string, "/fixture")
    }
}
