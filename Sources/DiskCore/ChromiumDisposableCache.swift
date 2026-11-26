import Foundation

/// Recognized HTTP and bytecode cache leaves only. Profile data and persistent
/// offline storage (including Service Worker and IndexedDB) are separate.
struct ChromiumDisposableCache: Sendable {
    let url: URL
    let application: String
    let owners: [URL]

    static func locations(home: URL, policy: FolderExclusions) -> [Self] {
        let support = home.appendingPathComponent("Library/Application Support")
        let caches = home.appendingPathComponent("Library/Caches")
        var result: [Self] = []
        func append(_ root: URL, _ application: String, _ dataOwner: URL) {
            let owners = [dataOwner, URL(fileURLWithPath: "/Applications").appendingPathComponent(application + ".app"),
                          home.appendingPathComponent("Applications/" + application + ".app")]
            guard !policy.contains(root.path) else { return }
            for leaf in ["Cache/Cache_Data", "Code Cache/js", "Code Cache/wasm", "Code Cache/electron-preload"] {
                let url = root.appendingPathComponent(leaf)
                if !policy.blocksCleanup(url), GeneratedCacheCandidate.physicalDirectory(url, owned: true) {
                    result.append(Self(url: url, application: application, owners: owners))
                }
            }
        }
        for application in ["Cursor", "Slack", "Linear"] {
            let owner = support.appendingPathComponent(application)
            append(owner, application, owner)
            append(caches.appendingPathComponent(application), application, owner)
        }
        let chromeSupport = support.appendingPathComponent("Google/Chrome")
        for root in [chromeSupport, caches.appendingPathComponent("Google/Chrome")] {
            guard !policy.contains(root.path), GeneratedCacheCandidate.physicalDirectory(root, owned: true),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name == "Default" || name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil {
                append(root.appendingPathComponent(name), "Google Chrome", chromeSupport.appendingPathComponent(name))
            }
        }
        return result
    }

    func accepts(_ scan: ScanResult) -> Bool {
        let preload = url.lastPathComponent == "electron-preload"
        var index = false, entry = false
        for node in scan.nodes.dropFirst() {
            guard !node.isSymlink else { return false }
            if preload {
                guard node.parent == 0, !node.isDirectory,
                      node.name.range(of: #"^[A-Fa-f0-9]{64}-[A-Fa-f0-9]{64}\.cache$"#, options: .regularExpression) != nil
                else { return false }
                entry = true
            } else if node.parent == 0 {
                if node.name == "index", !node.isDirectory { index = true; continue }
                if node.name == "index-dir", node.isDirectory { continue }
                guard !node.isDirectory,
                      node.name.range(of: #"^[a-f0-9]{16}_(0|1|s)$"#, options: .regularExpression) != nil else { return false }
                entry = true
            } else {
                guard let parent = node.parent, scan.nodes[parent].name == "index-dir", scan.nodes[parent].parent == 0,
                      !node.isDirectory, node.name == "the-real-index" else { return false }
            }
        }
        return entry && (preload || index)
    }
}
