import Foundation

/// Metadata-only developer-storage classifications. Build names are heuristics,
/// and temporary totals describe the current scanned footprint rather than
/// historical I/O or a promise that every byte can be reclaimed.
public enum DeveloperCategory: String, CaseIterable, Sendable {
    case claudeSessions
    case codexSessions
    case aiCaches
    /// Snapshots, support bundles and persistent tool data that need individual review.
    case toolData
    case gitRepositories
    case nodeModules
    case installedModules
    case pythonEnvironments
    case packageCaches
    case containerStorage
    case modelCaches
    case buildOutputs
    case temporary
    /// Installer payloads matched by extension: disk images, packages and
    /// similar single-file installers wherever they sit in the scan.
    case installers
    /// Files inside a directory named Downloads, untouched for
    /// `oldDownloadDays` and at least `oldDownloadMinimumBytes`.
    case oldDownloads
}

public struct DeveloperGroup: Sendable {
    public let category: DeveloperCategory
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let rootIDs: [Int]
    /// Allocated bytes attributed to each root after nested categories have
    /// been excluded. This can be less than a directory's raw scan total.
    public let rootAllocatedBytes: [Int: Int64]

    public init(
        category: DeveloperCategory,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        fileCount: Int,
        rootIDs: [Int],
        rootAllocatedBytes: [Int: Int64] = [:]
    ) {
        self.category = category
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.rootIDs = rootIDs
        self.rootAllocatedBytes = rootAllocatedBytes
    }
}

public enum DeveloperInsights {
    /// Staleness and size floors for `oldDownloads`. Age comes from file
    /// metadata, so it describes the file's last write, not whether the
    /// file is still needed.
    public static let oldDownloadDays = 90
    public static let oldDownloadMinimumBytes: Int64 = 16 * 1024 * 1024

    /// Classifies scan metadata without opening any files. A recognized
    /// subtree owns every descendant, keeping category totals nonoverlapping.
    /// Temporary paths are a fallback so recognizable developer storage under
    /// a macOS temporary directory still receives its more useful category.
    public static func analyze(_ scan: ScanResult) -> [DeveloperGroup] {
        analyze(scan, cancellationCheck: {})
    }

    public static func analyze(_ scan: ScanResult, now: Date = Date(), cancellationCheck: () throws -> Void) rethrows -> [DeveloperGroup] {
        var allocated = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, Int64.zero) })
        var logical = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, Int64.zero) })
        var files = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, 0) })
        var roots = Dictionary(uniqueKeysWithValues: DeveloperCategory.allCases.map { ($0, [Int]()) })
        var rootAllocated: [RootKey: Int64] = [:]

        // Only metadata names are examined; manifest contents remain unread.
        var composerProjects = Set<Int>(), rubyProjects = Set<Int>(), podProjects = Set<Int>()
        var dotNetProjects = Set<Int>()
        for node in scan.nodes {
            if node.id & 255 == 0 { try cancellationCheck() }
            guard !node.isDirectory, !node.isSymlink, let parent = node.parent else { continue }
            switch node.name.lowercased() {
            case "composer.json": composerProjects.insert(parent)
            case "gemfile": rubyProjects.insert(parent)
            case "podfile": podProjects.insert(parent)
            default: break
            }
            if ["csproj", "fsproj", "vbproj", "sln", "slnx"].contains((node.name as NSString).pathExtension.lowercased()) { dotNetProjects.insert(parent) }
        }
        var rootContext = contextForRootPath(scan.rootPath)
        if ToolStorage.containingData(path: scan.rootPath) != nil { rootContext.owner = .toolData }
        // Only directories can provide inherited context to another node.
        var contexts: [Int: NodeContext] = [:]

        for index in scan.nodes.indices {
            if index & 255 == 0 { try cancellationCheck() }
            let node = scan.nodes[index]
            let parentContext: NodeContext
            if let parent = node.parent, scan.nodes.indices.contains(parent), parent < index {
                parentContext = contexts[parent] ?? rootContext
            } else {
                parentContext = rootContext
            }

            var context = parentContext
            var explicitModules = false
            var explicitBuild = false
            if node.isDirectory, let parent = node.parent {
                let name = node.name.lowercased()
                explicitBuild = ["bin", "obj"].contains(name) && dotNetProjects.contains(parent)
                explicitModules = (name == "vendor" && composerProjects.contains(parent)) || (name == "pods" && podProjects.contains(parent))
                if name == "bundle", scan.nodes.indices.contains(parent), scan.nodes[parent].name == "vendor", let project = scan.nodes[parent].parent {
                    explicitModules = rubyProjects.contains(project)
                }
            }
            let toolData = ToolStorage.mayRecognize(name: node.name)
                && ToolStorage.recognizedRoot(path: scan.url(for: node.id).path) != nil
            if context.owner == nil, let category = toolData ? DeveloperCategory.toolData : explicitModules ? .installedModules : explicitBuild ? .buildOutputs : subtreeCategory(for: node, context: context) {
                context.owner = category
                context.ownerRootID = node.id
            }

            if context.owner == nil, !context.temporaryFallback, isTemporaryDirectory(node.name) {
                context.temporaryFallback = true
                context.temporaryRootID = node.id
            }

            if context.owner != nil, context.ownerRootID == nil {
                context.ownerRootID = node.id
            }
            if context.owner == nil, context.temporaryFallback, context.temporaryRootID == nil {
                context.temporaryRootID = node.id
            }

            updateScope(for: node, context: &context)
            if node.isDirectory { contexts[index] = context }

            guard !node.isDirectory, !node.isSymlink else { continue }
            let session = sessionCategory(for: node, context: context)
            let fileRule = fileCategory(for: node, context: context, now: now)
            let category = context.owner ?? session ?? fileRule ?? (context.temporaryFallback ? .temporary : nil)
            guard let category else { continue }

            let rootID: Int
            if context.owner != nil, let ownerRootID = context.ownerRootID {
                rootID = ownerRootID
            } else if session != nil || fileRule != nil {
                rootID = node.id
            } else if let temporaryRootID = context.temporaryRootID {
                rootID = temporaryRootID
            } else {
                continue
            }
            let key = RootKey(category: category, id: rootID)
            if rootAllocated[key] == nil {
                roots[category, default: []].append(rootID)
            }
            allocated[category] = saturatingAdd(allocated[category] ?? 0, node.allocatedBytes)
            logical[category] = saturatingAdd(logical[category] ?? 0, node.logicalBytes)
            files[category, default: 0] += 1
            rootAllocated[key] = saturatingAdd(rootAllocated[key] ?? 0, node.allocatedBytes)
        }

        return DeveloperCategory.allCases.map { category in
            let sortedRoots = (roots[category] ?? []).sorted {
                let left = rootAllocated[RootKey(category: category, id: $0)] ?? 0
                let right = rootAllocated[RootKey(category: category, id: $1)] ?? 0
                if left != right { return left > right }
                return $0 < $1
            }
            let rootBytes = Dictionary(uniqueKeysWithValues: sortedRoots.map {
                ($0, rootAllocated[RootKey(category: category, id: $0)] ?? 0)
            })
            return DeveloperGroup(
                category: category,
                allocatedBytes: allocated[category] ?? 0,
                logicalBytes: logical[category] ?? 0,
                fileCount: files[category] ?? 0,
                rootIDs: sortedRoots,
                rootAllocatedBytes: rootBytes
            )
        }
    }

    private static func subtreeCategory(for node: DiskNode, context: NodeContext) -> DeveloperCategory? {
        guard node.isDirectory else { return nil }
        return subtreeCategory(named: node.name.lowercased(), context: context)
    }

    private static func subtreeCategory(named name: String, context: NodeContext) -> DeveloperCategory? {
        if name == ".git" { return .gitRepositories }
        if name == "node_modules" { return .nodeModules }
        if name == "bower_components" { return .installedModules }
        if pythonDirectoryNames.contains(name) { return .pythonEnvironments }
        if name == "site-packages" { return .pythonEnvironments }

        if name == ".npm" || name == ".pnpm-store" { return .packageCaches }
        if name == "store", context.parentName == "pnpm", context.grandparentName == "library" { return .packageCaches }
        if packageCacheToolNames.contains(name), packageCacheParents.contains(context.parentName) {
            return .packageCaches
        }
        if name == "cache", [".dart", ".pub-cache", ".composer", ".swiftpm", ".sbt", ".ivy2"].contains(context.parentName) { return .packageCaches }
        if ["cache", "artifacts", "repositories"].contains(name), context.parentName == "org.swift.swiftpm", context.grandparentName == "caches" { return .packageCaches }
        if name == "diagnosticreports", context.parentName == "logs", context.grandparentName == "library" { return .temporary }
        if name == "cache", context.parentName == ".yarn" { return .packageCaches }
        if name == "cache", context.parentName == "install", context.grandparentName == ".bun" { return .packageCaches }
        if name == "mod", context.parentName == "pkg", context.grandparentName == "go" { return .packageCaches }
        if (name == "registry" || name == "git"), context.parentName == ".cargo" { return .packageCaches }
        if name == "caches", context.parentName == ".gradle" { return .packageCaches }
        if name == "dists", context.parentName == "wrapper", context.grandparentName == ".gradle" {
            return .packageCaches
        }
        if name == "repository", context.parentName == ".m2" { return .packageCaches }
        if name == "packages", context.parentName == ".nuget" { return .packageCaches }
        if ["providers", "modules"].contains(name), context.parentName == ".terraform" { return .packageCaches }

        if modelCacheToolNames.contains(name), packageCacheParents.contains(context.parentName) {
            return .modelCaches
        }
        if name == "models", context.parentName == ".ollama" { return .modelCaches }

        if context.containerTool, containerVolumeNames.contains(name) { return .containerStorage }
        if context.containerStorageScope, name == "storage" { return .containerStorage }

        if buildDirectoryNames.contains(name) || name.hasPrefix("cmake-build-") { return .buildOutputs }
        if context.aiHome != nil, context.isDirectAIHomeChild, isAICacheDirectory(name) { return .aiCaches }
        return nil
    }

    private static func sessionCategory(for node: DiskNode, context: NodeContext) -> DeveloperCategory? {
        guard node.name.lowercased().hasSuffix(".jsonl") else { return nil }
        if context.claudeSessionScope { return .claudeSessions }
        if context.codexSessionScope { return .codexSessions }
        return nil
    }

    /// Single-file categories claimed when no recognized subtree owns the
    /// file: installer payloads by extension, then stale Downloads files by
    /// context, age and size. Each matching file is its own finding root.
    private static func fileCategory(for node: DiskNode, context: NodeContext, now: Date) -> DeveloperCategory? {
        if installerExtensions.contains((node.name as NSString).pathExtension.lowercased()) {
            return .installers
        }
        guard context.inDownloads, node.logicalBytes >= oldDownloadMinimumBytes else { return nil }
        let days = Calendar.current.dateComponents([.day], from: node.modified, to: now).day ?? 0
        return days >= oldDownloadDays ? .oldDownloads : nil
    }

    private static func updateScope(for node: DiskNode, context: inout NodeContext) {
        updateScope(named: node.name.lowercased(), context: &context)
    }

    private static func updateScope(named name: String, context: inout NodeContext) {
        if name == ".claude" {
            context.aiHome = .claude
            context.isDirectAIHomeChild = true
        } else if name == ".codex" {
            context.aiHome = .codex
            context.isDirectAIHomeChild = true
        } else {
            if context.isDirectAIHomeChild, context.aiHome == .claude, name == "projects" {
                context.claudeSessionScope = true
            }
            if context.isDirectAIHomeChild,
               context.aiHome == .codex,
               name == "sessions" || name == "archived_sessions" {
                context.codexSessionScope = true
            }
            context.isDirectAIHomeChild = false
        }

        if containerToolDirectoryNames.contains(name) {
            context.containerTool = true
        }
        if name == "downloads" {
            // Inherited by descendants: a Downloads folder names intent
            // wherever it sits in the scanned tree.
            context.inDownloads = true
        }
        if name == "containers", context.parentName == "share", context.grandparentName == ".local" {
            context.containerStorageScope = true
        }
        context.grandparentName = context.parentName
        context.parentName = name
    }

    private static func contextForRootPath(_ path: String) -> NodeContext {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard !components.isEmpty else { return NodeContext() }

        var context = NodeContext()
        for component in components {
            if context.owner == nil, let category = subtreeCategory(named: component, context: context) {
                context.owner = category
            }
            updateScope(named: component, context: &context)
        }

        // A selected /tmp/project should not classify all of project as
        // temporary. Only the selected temporary directory itself gets this
        // fallback; descendant developer directories can still win.
        if let last = components.last,
           isTemporaryDirectory(last) || isMacOSTemporaryRoot(components) {
            context.temporaryFallback = true
        }
        return context
    }

    private static func isMacOSTemporaryRoot(_ components: [String]) -> Bool {
        guard components.count >= 5,
              components.last == "t",
              let folders = components.lastIndex(of: "folders"),
              folders + 3 == components.count - 1,
              folders > 0,
              components[folders - 1] == "var",
              folders == 1 || (folders == 2 && components.first == "private") else {
            return false
        }
        return !components[folders + 1].isEmpty && !components[folders + 2].isEmpty
    }

    private static func isAICacheDirectory(_ name: String) -> Bool {
        name == "cache" || name.hasPrefix("cache-") || name.hasPrefix("cache_")
    }

    private static func isTemporaryDirectory(_ name: String) -> Bool {
        ["tmp", "temp", "temporary"].contains(name.lowercased())
    }
}

private enum AIHome: Equatable {
    case claude
    case codex
}

private struct NodeContext {
    var owner: DeveloperCategory?
    var ownerRootID: Int?
    var temporaryFallback = false
    var temporaryRootID: Int?
    var aiHome: AIHome?
    var isDirectAIHomeChild = false
    var claudeSessionScope = false
    var codexSessionScope = false
    var parentName = ""
    var grandparentName = ""
    var containerTool = false
    var containerStorageScope = false
    var inDownloads = false
}

private struct RootKey: Hashable {
    let category: DeveloperCategory
    let id: Int
}

private let buildDirectoryNames: Set<String> = [
    ".build", ".next", ".nuxt", ".svelte-kit", ".angular", ".dart_tool", "dist", "build", "deriveddata", "target",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".cxx", ".externalnativebuild"
]

private let pythonDirectoryNames: Set<String> = [
    ".venv", "venv", ".tox", ".nox", "__pypackages__"
]

private let packageCacheParents: Set<String> = [".cache", "caches"]
private let packageCacheToolNames: Set<String> = ["npm", "pnpm", "yarn", "pip", "uv", "homebrew", "go-build", "cocoapods", "composer", "ccache", "sccache", "ms-playwright", "playwright", "electron", "cypress", "puppeteer", "coursier", "ruby", "dart", "org.swift.swiftpm"]
private let modelCacheToolNames: Set<String> = [
    "huggingface", "torch", "whisper", "transformers", "diffusers", "sentence-transformers"
]
private let containerToolDirectoryNames: Set<String> = [
    "com.docker.docker", "group.com.docker", "com.podman.desktop", "com.utmapp.utm",
    "com.parallels.desktop", "com.vmware.fusion"
]
private let containerVolumeNames: Set<String> = ["vms", "vm", "disks"]

/// Single-file installer payloads. `.iso` and `.ipsw` images live here too:
/// both are device/disk installers in practice, and each finding shows its
/// full path so a real archive is easy to keep.
private let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "ipsw"]

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? Int64.max : Int64.min) : value
}
