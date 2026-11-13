import Foundation
import DiskCore

struct CleanupReviewFilter {
    var query = ""

    func matchingIDs(_ selected: [Int], in scan: ScanResult) -> [Int] {
        guard !query.isEmpty else { return selected }
        return selected.filter { scan.url(for: $0).path.localizedCaseInsensitiveContains(query) }
    }

    func hiddenCount(_ selected: [Int], in scan: ScanResult) -> Int {
        selected.count - matchingIDs(selected, in: scan).count
    }

    mutating func revealHiddenSelection(_ selected: [Int], in scan: ScanResult) -> Bool {
        guard hiddenCount(selected, in: scan) > 0 else { return false }
        query = ""
        return true
    }
}

enum CleanupReviewLabels {
    private static let projectFolders: Set<String> = ["node_modules", ".build", "__pycache__", ".next", ".nuxt"]

    static func title(_ id: Int, in scan: ScanResult) -> String {
        let node = scan.nodes[id]
        if projectFolders.contains(node.name), let parent = node.parent, scan.nodes.indices.contains(parent) {
            return StorageLabels.name(scan.nodes[parent])
        }
        return StorageLabels.name(node)
    }

    static func subtitle(_ id: Int, in scan: ScanResult) -> String {
        let node = scan.nodes[id]
        let url = scan.url(for: id)
        if title(id, in: scan) != StorageLabels.name(node) {
            return "\(StorageLabels.name(node)) · \(StorageLabels.location(url.deletingLastPathComponent().path))"
        }
        return StorageLabels.location(url.path)
    }
}
