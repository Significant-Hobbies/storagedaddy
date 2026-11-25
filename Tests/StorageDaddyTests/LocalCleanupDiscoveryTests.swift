import Foundation
import DiskCore
import Testing
@testable import StorageDaddy

/// Opt-in, read-only timing of the dashboard review on the Mac's saved project roots.
@MainActor struct LocalCleanupDiscoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGEDADDY_TIME_LOCAL_REVIEW"] == "1"), .timeLimit(.minutes(10)))
    func measureLocalReview() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.persistentDomain(forName: "local.fleet.storagedaddy") ?? [:]
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["excludedFolders"] = saved["excludedFolders"] ?? []
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let preferences = try #require(UserDefaults(suiteName: "local.fleet.storagedaddy"))
        let model = ExplorerModel(developerCleanupPreferences: preferences)
        let capacity = try #require(StartupCapacity(report: SystemInventory.collect()))
        let start = ContinuousClock.now
        model.openSpaceTarget(capacity)
        var sawItems = false, sawWorktrees = false
        while model.busy {
            if let plan = model.developerCleanupPlan {
                if !sawItems && !plan.items.isEmpty && model.canEditCleanupReview {
                    print("First actionable review", start.duration(to: .now))
                    sawItems = true
                }
                if !sawWorktrees && !plan.idleWorktrees.isEmpty {
                    print("First idle worktrees", start.duration(to: .now), plan.idleWorktrees.count)
                    sawWorktrees = true
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let plan = try #require(model.developerCleanupPlan)
        let selected = plan.items.filter { model.developerCleanupSelectedIDs.contains($0.id) }
        let modules = { (path: String) in path.hasSuffix("/node_modules") }
        print("Completed review", start.duration(to: .now), "items", selected.count, "allocated bytes",
              selected.reduce(Int64.zero) { $0 + $1.allocatedBytes }, "linked worktrees", plan.idleWorktrees.count,
              "Fleet checks", plan.checkedWorktrees.count, "Fleet approved", plan.checkedWorktrees.values.filter { $0.eligible }.count,
              "node_modules ready", selected.filter { modules($0.path) }.count,
              "node_modules kept", plan.withheld.filter { modules($0.item.path) }.count)
        #expect(model.developerCleanupOutcome == nil)
    }
}
