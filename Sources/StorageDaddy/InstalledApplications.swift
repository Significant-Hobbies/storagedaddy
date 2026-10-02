import SwiftUI
import DiskCore
import CoreServices

struct InstalledApplication: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL
    var allocatedBytes: Int64?
    /// `nil` is either still pending or could not be measured; this flag keeps
    /// those states distinct in the UI without turning an incomplete bundle
    /// scan into a misleading total.
    var sizeUnavailable = false
    var lastUsed: Date? = nil
    var iconPNG: Data? = nil
    var category = "Uncategorized"
}

enum ApplicationCategory {
    static func title(for rawValue: String?, bundleIdentifier: String? = nil) -> String {
        // Existing signed releases of these apps predate category metadata.
        if rawValue == nil, let bundleIdentifier,
           ["com.significanthobbies.performancedaddy", "com.significanthobbies.browserdaddy"].contains(bundleIdentifier) {
            return "Utilities"
        }
        guard let rawValue, rawValue.hasPrefix("public.app-category.") else { return "Uncategorized" }
        let key = String(rawValue.dropFirst("public.app-category.".count))
        let gameCategories: Set<String> = ["games", "action-games", "adventure-games", "arcade-games", "board-games", "card-games", "casino-games", "dice-games", "educational-games", "family-games", "kids-games", "music-games", "puzzle-games", "racing-games", "role-playing-games", "simulation-games", "sports-games", "strategy-games", "trivia-games", "word-games"]
        if gameCategories.contains(key) { return "Games" }
        return [
            "business": "Business", "developer-tools": "Developer Tools",
            "education": "Education", "entertainment": "Entertainment",
            "finance": "Finance", "graphics-design": "Graphics & Design",
            "healthcare-fitness": "Health & Fitness", "lifestyle": "Lifestyle",
            "medical": "Medical", "music": "Music", "news": "News",
            "photography": "Photography", "productivity": "Productivity",
            "reference": "Reference", "social-networking": "Social Networking",
            "sports": "Sports", "travel": "Travel", "utilities": "Utilities",
            "video": "Video", "weather": "Weather", "books": "Books"
        ][key] ?? "Uncategorized"
    }
}

enum ApplicationSort: String, CaseIterable {
    case name = "Name", size = "Size", lastUsed = "Last used"
}

@MainActor final class InstalledApplicationsModel: ObservableObject {
    @Published private(set) var apps: [InstalledApplication] = []
    @Published private(set) var sortedApps: [InstalledApplication] = []
    @Published var sort: ApplicationSort = .size { didSet { rebuildOrder() } }
    @Published var ascending = false { didSet { rebuildOrder() } }

    var measuredBundleBytes: Int64 {
        apps.compactMap(\.allocatedBytes).reduce(0, +)
    }

    var measuredCount: Int { apps.lazy.filter { $0.allocatedBytes != nil }.count }
    var pendingCount: Int { apps.lazy.filter { $0.allocatedBytes == nil && !$0.sizeUnavailable }.count }
    var unavailableCount: Int { apps.lazy.filter { $0.allocatedBytes == nil && $0.sizeUnavailable }.count }

    var orderLabel: String {
        switch sort {
        case .name: ascending ? "A to Z" : "Z to A"
        case .size: ascending ? "Smallest first" : "Largest first"
        case .lastUsed: ascending ? "Oldest first" : "Newest first"
        }
    }

    private func rebuildOrder() {
        // Keep discovery order separate: background measurements address that array.
        sortedApps = apps.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if (lhs.allocatedBytes == nil) != (rhs.allocatedBytes == nil) { return lhs.allocatedBytes != nil }
                comparison = compare(lhs.allocatedBytes, rhs.allocatedBytes)
            case .lastUsed:
                if (lhs.lastUsed == nil) != (rhs.lastUsed == nil) { return lhs.lastUsed != nil }
                comparison = compare(lhs.lastUsed, rhs.lastUsed)
            }
            if comparison == .orderedSame {
                let name = lhs.name.localizedStandardCompare(rhs.name)
                return name == .orderedSame ? lhs.id < rhs.id : name == .orderedAscending
            }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        guard let lhs, let rhs, lhs != rhs else { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
    @Published var loading = false
    @Published var status = "Discovering installed apps…"
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var hasLoaded = false

    func loadIfNeeded() async { if !hasLoaded, !loading { refresh() } }
    func cancel() { task?.cancel(); generation = UUID(); loading = false; status = "Size calculation paused. Refresh to continue." }
    func refresh() {
        guard !removalBusy || movingApplication else { return }
        task?.cancel()
        let version = UUID(); generation = version
        loading = true; status = "Discovering installed apps…"
        task = Task { [weak self] in
            let discovery = Task.detached(priority: .utility) { try Self.discover() }
            do {
                let found = try await withTaskCancellationHandler { try await discovery.value } onCancel: { discovery.cancel() }
                try Task.checkCancellation()
                guard let self, self.generation == version else { return }
                // Discovery may take a moment, so existing rows remain on
                // screen until it finishes. The replacement starts with no
                // sizes: a failed new scan must never look measured because a
                // previous refresh happened to have a cached value.
                self.apps = found
                self.rebuildOrder(); self.hasLoaded = true
                var unavailable = 0
                for (index, app) in found.enumerated() {
                    try Task.checkCancellation()
                    self.status = "Measuring \(index + 1) of \(found.count) apps · \(app.name)"
                    // The filesystem scanner runs outside the main actor. Only
                    // this one app is measured; the disk scan is never searched.
                    do {
                        let scan = try await DiskScanner.scan(root: app.url)
                        try Task.checkCancellation()
                        guard self.generation == version else { return }
                        if scan.skipped == 0, scan.errors.isEmpty {
                            if let allocatedBytes = scan.nodes.first?.allocatedBytes {
                                self.apps[index].allocatedBytes = allocatedBytes
                                self.apps[index].sizeUnavailable = false
                            } else {
                                self.apps[index].allocatedBytes = nil
                                self.apps[index].sizeUnavailable = true
                                unavailable += 1
                            }
                            self.rebuildOrder()
                        } else {
                            self.apps[index].allocatedBytes = nil
                            self.apps[index].sizeUnavailable = true
                            self.rebuildOrder()
                            unavailable += 1
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard self.generation == version else { return }
                        self.apps[index].allocatedBytes = nil
                        self.apps[index].sizeUnavailable = true
                        self.rebuildOrder()
                        unavailable += 1
                    }
                }
                self.loading = false
                self.status = "\(found.count) apps found in standard application folders" + (unavailable > 0 ? " · \(unavailable) sizes unavailable" : "")
            } catch {
                guard let self, self.generation == version else { return }
                self.loading = false
                self.status = error is CancellationError ? "Discovery cancelled" :
                    (self.hasLoaded ? "Refresh failed. Showing the previous inventory. " : "") + "Unable to finish app discovery. Refresh to try again."
            }
        }
    }

    @Published var removalReview: InstalledApplicationRemovalReview?
    @Published private(set) var preparingRemovalID: String?
    @Published private(set) var movingApplication = false
    @Published var removalNotice: String?
    @Published var removalError: String?
    private var removalTask: Task<Void, Never>?

    var removalBusy: Bool { preparingRemovalID != nil || movingApplication || removalReview != nil }

    func removalBlockReason(for app: InstalledApplication) -> String? {
        let path = app.url.standardizedFileURL.path
        let personal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(personal + "/") else {
            return "macOS system applications are protected."
        }
        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        if path == ownPath || ownPath.hasPrefix(path + "/") {
            return "storagedaddy cannot remove itself while running."
        }
        if NSWorkspace.shared.runningApplications.contains(where: {
            guard let running = $0.bundleURL?.standardizedFileURL.path else { return false }
            return running == path || running.hasPrefix(path + "/")
        }) { return "Quit this application before removing it." }
        return nil
    }

    func reviewRemoval(of app: InstalledApplication) {
        guard !removalBusy else { return }
        removalError = nil; removalNotice = nil
        if let reason = removalBlockReason(for: app) { removalError = reason; return }
        preparingRemovalID = app.id
        removalTask = Task {
            defer { preparingRemovalID = nil }
            do {
                let plan = try await ApplicationRemovalPlan.prepare(url: app.url)
                try Task.checkCancellation()
                if let reason = removalBlockReason(for: app) { removalError = reason; return }
                removalReview = InstalledApplicationRemovalReview(application: app, plan: plan)
            } catch is CancellationError { }
            catch {
                removalError = "Could not fully verify \(app.name). Nothing moved. Refresh and try again, or review the app in Finder."
            }
        }
    }

    func cancelRemoval() {
        guard !movingApplication else { return }
        removalTask?.cancel()
        removalReview = nil
        removalError = nil
    }

    func confirmRemoval(_ review: InstalledApplicationRemovalReview, onRemoved: @escaping (URL) -> Void) {
        guard !movingApplication, removalReview?.id == review.id else { return }
        movingApplication = true; removalError = nil
        removalTask = Task {
            defer { movingApplication = false }
            do {
                // Recheck after confirmation: an app may have launched or updated
                // while its review was open. No privilege escalation or forced quit.
                try await review.plan.validate()
                try Task.checkCancellation()
                if let reason = removalBlockReason(for: review.application) {
                    removalError = reason; return
                }
                try review.plan.validateIdentity()
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: review.plan.url, resultingItemURL: &trashedURL)
                // Stop the measurement task before changing its indexed array.
                cancel()
                apps.removeAll { $0.id == review.application.id }
                rebuildOrder()
                removalReview = nil
                removalNotice = "\(review.application.name) moved to Trash. Documents and support data were kept."
                onRemoved(review.plan.url)
                refresh()
            } catch {
                removalError = "Could not move \(review.application.name) to Trash. It may have changed, be unreadable, or require permission. Nothing else was removed. Refresh and review it again, or use Finder."
            }
        }
    }

    nonisolated private static func discover() throws -> [InstalledApplication] {
        let manager = FileManager.default
        let roots = AppReferenceDiscovery.standardRoots(home: manager.homeDirectoryForCurrentUser)
        var found: [String: InstalledApplication] = [:]
        for root in roots {
            try Task.checkCancellation()
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                try Task.checkCancellation()
                guard url.pathExtension.lowercased() == "app" else { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let lastUsed: Date?
                if let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) {
                    lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                } else { lastUsed = nil }
                let bundle = Bundle(url: url)
                let declaredName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                let name = declaredName?.trimmingCharacters(in: .whitespacesAndNewlines)
                found[url.path] = InstalledApplication(id: url.path, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent, url: url, allocatedBytes: nil, lastUsed: lastUsed, iconPNG: appIcon(at: url), category: ApplicationCategory.title(for: bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String, bundleIdentifier: bundle?.bundleIdentifier))
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Rasterize once off the main actor at 2x display size instead of retaining
    /// every resolution of each app's icon or fetching it during row rendering.
    nonisolated private static func appIcon(at url: URL) -> Data? {
        autoreleasepool {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: 80, height: 80), from: .zero, operation: .copy, fraction: 1)
            return bitmap.representation(using: .png, properties: [:])
        }
    }

}
