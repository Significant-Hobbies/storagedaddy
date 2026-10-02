import Foundation
import DiskCore

/// A reference for standard application folders, not proof that all apps on
/// every volume have been inventoried. Reads only existing bundle metadata.
enum AppReferenceDiscovery {
    static func standardRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices/Applications")]
    }
    static func collect(roots: [URL], now: Date = Date(),
        maximumEntries: Int = 20_000, maximumApplications: Int = 5_000, maximumDepth: Int = 12,
        metadata: (URL) -> AppLeftoverInventory.Application? = bundleMetadata) throws -> AppLeftoverInventory {
        let manager = FileManager.default
        var complete = true, applications: [AppLeftoverInventory.Application] = []
        var visited = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        rootLoop: for root in roots {
            try Task.checkCancellation()
            guard maximumEntries > 0, maximumApplications > 0, maximumDepth > 0 else { complete = false; break }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                // A missing optional folder is empty; inaccessible roots are unknown.
                do { _ = try root.resourceValues(forKeys: [.isDirectoryKey]) }
                catch let error as NSError {
                    if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError { complete = false }
                }
                continue
            }
            // A symbolic root cannot establish absence without following
            // unknown scope. Inaccessible metadata also fails closed.
            guard let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]), rootValues.isSymbolicLink != true else {
                complete = false; continue
            }
            guard isDirectory.boolValue, let entries = manager.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in complete = false; return true }) else {
                complete = false; continue
            }
            for case let url as URL in entries {
                try Task.checkCancellation()
                guard visited < maximumEntries, applications.count < maximumApplications, ContinuousClock.now < deadline else {
                    complete = false; break rootLoop
                }
                visited += 1
                guard entries.level <= maximumDepth else { complete = false; entries.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else {
                    complete = false; entries.skipDescendants(); continue
                }
                guard url.pathExtension.lowercased() == "app" else { continue }
                guard values.isDirectory == true,
                      let app = metadata(url), app.bundleID.map(AppLeftoverReview.isIdentifier) == true,
                      !app.names.isEmpty else { complete = false; continue }
                applications.append(app)
            }
        }
        return AppLeftoverInventory(applications: applications, completeness: complete ? .complete : .partial, checkedAt: now)
    }
    static func bundleMetadata(at url: URL) -> AppLeftoverInventory.Application? {
        guard let bundle = Bundle(url: url) else { return nil }
        let declared = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                        bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
        return AppLeftoverInventory.Application(bundleID: bundle.bundleIdentifier,
            names: declared + [url.deletingPathExtension().lastPathComponent])
    }
}
