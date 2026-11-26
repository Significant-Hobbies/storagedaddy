import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

private enum RefreshFailure: Error { case unavailable }

private actor RefreshSequence<Value: Sendable> {
    private var calls = 0
    private var firstLoad: CheckedContinuation<Void, Never>?
    private var startObserver: CheckedContinuation<Void, Never>?
    let first: Value
    let second: Value
    let blockFirst: Bool

    init(first: Value, second: Value, blockFirst: Bool = false) {
        self.first = first; self.second = second; self.blockFirst = blockFirst
    }

    func next() async throws -> Value {
        calls += 1
        if calls == 1 {
            if blockFirst {
                await withCheckedContinuation { continuation in
                    firstLoad = continuation
                    startObserver?.resume()
                    startObserver = nil
                }
            }
            return first
        }
        if blockFirst { return second }
        throw RefreshFailure.unavailable
    }

    func waitUntilStarted() async {
        guard firstLoad == nil else { return }
        await withCheckedContinuation { startObserver = $0 }
    }

    func resumeFirst() {
        firstLoad?.resume()
        firstLoad = nil
    }
}

@Suite struct InventoryRefreshTests {
    private func sessions(_ suffix: String) throws -> AISessionInventoryReport {
        try AISessionInventory.discover(configuration: .init(
            home: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent-sessions-\(UUID())-\(suffix)")))
    }

    @Test @MainActor func sessionsRetainInventoryAndShowRefreshFailure() async throws {
        let expected = try sessions("retained")
        let sequence = RefreshSequence(first: expected, second: expected)
        let model = AISessionsModel(discover: { try await sequence.next() })
        await model.load()
        await model.load()
        #expect(model.report == expected)
        #expect(model.errorMessage != nil)
        #expect(!model.loading)
    }

    @Test @MainActor func supersededSessionsCannotOverwriteNewResult() async throws {
        let newer = try sessions("new")
        let sequence = RefreshSequence(first: try sessions("old"), second: newer, blockFirst: true)
        let model = AISessionsModel(discover: { try await sequence.next() })
        let old = Task { await model.load() }
        await sequence.waitUntilStarted()
        await model.load()
        await sequence.resumeFirst()
        await old.value
        #expect(model.report == newer)
        #expect(model.errorMessage == nil)
        #expect(!model.loading)
    }
}
