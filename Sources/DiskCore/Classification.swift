import Foundation

/// Scan-metadata explanations, not cleanup permission or proof of recoverability.
public enum StorageKind: String, CaseIterable, Sendable {
    case code = "Code"
    case caches = "Caches"
    case toolchains = "Toolchains"
    case packages = "Packages"
    case git = "Git"
    case media = "Media"
    case documents = "Documents"
    case agents = "AI & agents"
    case generic = "Other"

    public static let projectMarkers: Set<String> = ["package.json", "cargo.toml", "pyproject.toml", "go.mod", "package.swift", "pom.xml", "build.gradle", "build.gradle.kts", "pubspec.yaml", "build.zig", "gemfile", "composer.json", "cmakelists.txt", "project.godot", "projectsettings", "assets", "requirements.txt", "mix.exs", "deno.json", "deno.jsonc"]

    static func category(_ category: DeveloperCategory) -> StorageKind {
        switch category {
        case .gitRepositories: .git
        case .nodeModules, .installedModules, .packageCaches: .packages
        case .pythonEnvironments, .containerStorage: .toolchains
        case .aiCaches, .modelCaches, .buildOutputs, .temporary: .caches
        case .claudeSessions, .codexSessions: .agents
        case .installers, .oldDownloads: .generic
        }
    }

    static func metadata(_ node: DiskNode, childNames: Set<String>) -> StorageKind {
        if node.isDirectory {
            if !childNames.isDisjoint(with: projectMarkers.subtracting(["assets", "projectsettings"])) || childNames.isSuperset(of: ["assets", "projectsettings"]) || childNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".uproject") }) { return .code }
            switch node.name.lowercased() {
            case "caches", ".cache", "deriveddata": return .caches
            case ".rustup", ".gradle", ".m2": return .toolchains
            case ".codex", ".claude", ".cursor": return .agents
            case "movies", "music", "pictures": return .media
            case "documents": return .documents
            default: return .generic
            }
        }
        switch URL(fileURLWithPath: node.name).pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "mp3", "wav", "flac", "jpg", "jpeg", "png", "heic", "gif", "webp": return .media
        case "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "xlsx", "csv": return .documents
        case "swift", "rs", "ts", "tsx", "js", "jsx", "py", "go", "c", "cpp", "h", "java", "kt", "rb", "dart", "zig": return .code
        default: return .generic
        }
    }
}

/// Reuses DeveloperInsights ownership and builds descendant counts once per scan.
/// All inputs are names/tree metadata; this does not open files or run tools.
public struct StorageMapIndex: Sendable {
    public let kinds: [StorageKind]
    public let fileCounts: [Int64]
    public let reviewCandidates: Set<Int>

    public init(scan: ScanResult, groups suppliedGroups: [DeveloperGroup]? = nil) {
        self.init(scan: scan, groups: suppliedGroups, cancellationCheck: {})
    }

    public init(scan: ScanResult, groups suppliedGroups: [DeveloperGroup]? = nil, cancellationCheck: () throws -> Void) rethrows {
        let groups = try suppliedGroups ?? DeveloperInsights.analyze(scan, cancellationCheck: cancellationCheck)
        var categories = [DeveloperCategory?](repeating: nil, count: scan.nodes.count)
        for group in groups {
            for root in group.rootIDs where scan.nodes.indices.contains(root) { categories[root] = group.category }
        }
        var kinds = [StorageKind](repeating: .generic, count: scan.nodes.count)
        var counts = [Int64](repeating: 0, count: scan.nodes.count)
        var candidates = Set<Int>()
        let candidateCategories: Set<DeveloperCategory> = [.packageCaches, .nodeModules, .installedModules, .buildOutputs, .aiCaches]
        for node in scan.nodes {
            if node.id & 255 == 0 { try cancellationCheck() }
            guard scan.nodes.indices.contains(node.id) else { continue }
            if categories[node.id] == nil, let parent = node.parent, scan.nodes.indices.contains(parent), parent < node.id { categories[node.id] = categories[parent] }
            let names = Set(node.children.filter { scan.nodes.indices.contains($0) }.map { scan.nodes[$0].name.lowercased() })
            kinds[node.id] = categories[node.id].map(StorageKind.category) ?? StorageKind.metadata(node, childNames: names)
            if let category = categories[node.id], candidateCategories.contains(category), node.parent.flatMap({ scan.nodes.indices.contains($0) ? categories[$0] : nil }) != category { candidates.insert(node.id) }
            if !node.isDirectory { counts[node.id] = 1 }
        }
        // Scanner and validated snapshot nodes place parents before children.
        for node in scan.nodes.reversed() {
            if node.id & 255 == 0 { try cancellationCheck() }
            guard scan.nodes.indices.contains(node.id), let parent = node.parent, scan.nodes.indices.contains(parent), parent < node.id else { continue }
            let (sum, overflow) = counts[parent].addingReportingOverflow(counts[node.id])
            counts[parent] = overflow ? Int64.max : sum
        }
        self.kinds = kinds; self.fileCounts = counts; self.reviewCandidates = candidates
    }
}
