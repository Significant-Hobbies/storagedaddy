import AppHealth
import Foundation
import Testing
@testable import StorageDaddy

private actor HealthLifecycleRecorder: NativeHealthClient {
    var calls: [String] = []
    func setActive(_ value: Bool) { calls.append(value ? "active" : "inactive") }
    func close() { calls.append("close") }
}

private actor HeartbeatTransport: AppHealthTransport {
    var bodies: [Data] = []
    func send(_ request: URLRequest) async throws -> AppHealthResponse {
        if let body = request.httpBody { bodies.append(body) }
        return AppHealthResponse(statusCode: 204)
    }
}

@MainActor struct NativeAppHealthTests {
    let key = "ahk_native_" + String(repeating: "a", count: 64)

    @Test func missingOrInvalidKeyDoesNotCreateAClient() {
        var created = 0
        for value in [nil, "", "invalid", "ahk_native_abc", "ahk_native_" + String(repeating: "a", count: 64) + "\n"] as [String?] {
            let health = NativeAppHealth(publicKey: value) { _ in
                created += 1
                return HealthLifecycleRecorder()
            }
            #expect(!health.isEnabled)
        }
        #expect(created == 0)
    }

    @Test func lifecycleIsOrderedAndCloseStopsAdmission() async {
        let recorder = HealthLifecycleRecorder()
        let health = NativeAppHealth(publicKey: key) { _ in recorder }
        health.setActive(true)
        health.setActive(false)
        health.setActive(true)
        await health.close()
        health.setActive(true)
        await health.close()
        #expect(await recorder.calls == ["active", "inactive", "active", "inactive", "close"])
    }

    @Test func realSDKHeartbeatHasNoEventsLogsOrFileIdentity() async throws {
        let transport = HeartbeatTransport()
        let client = try AppHealthClient(endpoint: NativeAppHealth.endpoint, publicKey: key, transport: transport)
        let health = NativeAppHealth(publicKey: key) { _ in client }
        await client.setActive(true)
        await client.flush()
        await health.close()
        let bodies = await transport.bodies
        #expect(!bodies.isEmpty)
        for body in bodies {
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(payload.keys) == ["schema_version", "public_key", "batch_id", "session_id", "active", "events", "logs"])
            #expect((payload["events"] as? [Any])?.isEmpty == true)
            #expect((payload["logs"] as? [Any])?.isEmpty == true)
        }
    }
}
