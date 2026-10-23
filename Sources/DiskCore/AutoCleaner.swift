import Foundation

/// A stale, usually-regenerable folder worth reviewing. Notify-only: the
/// Auto Cleaner never deletes or moves anything itself; suggestions stage
/// through the normal cleanup review like any manual pick.
public struct AutoCleanerSuggestion: Identifiable, Sendable {
    /// Node id inside the producing scan.
    public let id: Int
    public let category: DeveloperCategory
    public let path: String
    public let allocatedBytes: Int64
    /// Whole days since the folder's metadata was last modified. This is not
    /// an activity signal — a stale folder can still be in active use.
    public let staleDays: Int
    public let thresholdDays: Int
}

public enum AutoCleaner {
    /// Staleness thresholds in days for the categories the owner named:
    /// old builds, old node modules and old caches. Conservative defaults;
    /// loosening them is a product decision, not a code default.
    public static let staleDays: [DeveloperCategory: Int] = [
        .buildOutputs: 14,
        .nodeModules: 30,
        .packageCaches: 30,
    ]

    /// Suggestions below this size are not worth interrupting the owner for.
    public static let minimumBytes: Int64 = 16 * 1024 * 1024

    /// Ranks developer findings by staleness. Package caches additionally must
    /// live inside the bounded system cache stores — a loose cache match under
    /// a project is never auto-suggested.
    public static func suggestions(
        scan: ScanResult,
        findings: [DeveloperFinding],
        now: Date = Date(),
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    ) -> [AutoCleanerSuggestion] {
        findings.compactMap { finding in
            guard let threshold = staleDays[finding.category],
                  finding.allocatedBytes >= minimumBytes,
                  scan.nodes.indices.contains(finding.id) else { return nil }
            let path = scan.url(for: finding.id).path
            guard CleanupGuidance.requiredNativeCleaner(path: path, home: home) == nil else { return nil }
            guard !CleanupGuidance.isInstalledRuntime(path: path) else { return nil }
            if finding.category == .packageCaches,
               !CleanupGuidance.isSuggestedCache(category: finding.category, path: path, home: home) {
                return nil
            }
            let days = Calendar.current.dateComponents([.day], from: finding.lastModified, to: now).day ?? 0
            guard days >= threshold else { return nil }
            return AutoCleanerSuggestion(
                id: finding.id,
                category: finding.category,
                path: path,
                allocatedBytes: finding.allocatedBytes,
                staleDays: days,
                thresholdDays: threshold,
            )
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
}
