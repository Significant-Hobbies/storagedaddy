import AppHealth
import Foundation

protocol NativeHealthClient: Sendable {
    func setActive(_ value: Bool) async
    func close() async
}

extension AppHealthClient: NativeHealthClient {}

/// Explicit per-user opt-in, read once at launch. There is no bundled key or
/// event/log API in this adapter, and no client is created while disabled.
@MainActor final class NativeAppHealth {
    static let preferenceKey = "StorageDaddyAppHealthPublicKey"
    static let endpoint = URL(string: "https://health.sassmaker.com")!
    private let client: (any NativeHealthClient)?
    private var pending: Task<Void, Never>?
    private var closing = false
    var isEnabled: Bool { client != nil }

    init(publicKey: String?, factory: (String) throws -> any NativeHealthClient = {
        try AppHealthClient(endpoint: NativeAppHealth.endpoint, publicKey: $0)
    }) {
        guard let publicKey, publicKey.utf8.count == 75,
              publicKey.range(of: "^ahk_native_[a-f0-9]{64}$", options: .regularExpression) != nil else {
            client = nil
            return
        }
        client = try? factory(publicKey)
    }

    func setActive(_ active: Bool) {
        guard !closing, let client else { return }
        let previous = pending
        pending = Task {
            await previous?.value
            await client.setActive(active)
        }
    }

    func close() async {
        if closing { await pending?.value; return }
        closing = true
        guard let client else { return }
        let previous = pending
        let task = Task {
            await previous?.value
            await client.setActive(false)
            await client.close()
        }
        pending = task
        await task.value
    }
}
