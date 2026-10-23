import Foundation

public struct DeveloperReport: Sendable {
    public let findings: [DeveloperFinding]
    public let projects: [DeveloperProject]

    public init(findings: [DeveloperFinding], projects: [DeveloperProject]) {
        self.findings = findings
        self.projects = projects
    }

    /// Builds actionable metadata from already-classified storage. It never
    /// opens files: project markers are names supplied by the scan.
    public static func build(scan: ScanResult, groups: [DeveloperGroup]) -> Self {
        build(scan: scan, groups: groups, cancellationCheck: {})
    }

    public static func build(
        scan: ScanResult,
        groups: [DeveloperGroup],
        cancellationCheck: () throws -> Void
    ) rethrows -> Self {
        let roots = attributedRoots(from: groups, nodeCount: scan.nodes.count)
        var artifactRootByNode: [Int: Int] = [:]
        var markerDirectories = Set<Int>()
        var markerNamesByDirectory: [Int: Set<String>] = [:]

        for index in scan.nodes.indices {
            if index & 255 == 0 { try cancellationCheck() }
            let node = scan.nodes[index]
            let inheritedRoot: Int?
            if let parent = node.parent, scan.nodes.indices.contains(parent), parent < index {
                inheritedRoot = artifactRootByNode[parent]
            } else {
                inheritedRoot = nil
            }
            let root = roots[node.id] == nil ? inheritedRoot : node.id
            if node.isDirectory, let root { artifactRootByNode[index] = root }

            if markerCanDefineProject(node, artifactRootID: root, roots: roots),
               let parent = node.parent,
               scan.nodes.indices.contains(parent),
               scan.nodes[parent].isDirectory {
                markerDirectories.insert(parent)
                markerNamesByDirectory[parent, default: []].insert(node.name.lowercased())
            }
        }

        var findings: [DeveloperFinding] = []
        findings.reserveCapacity(roots.count)
        var projectAccumulators: [Int: ProjectAccumulator] = [:]

        for (offset, root) in roots.values.enumerated() {
            if offset & 255 == 0 { try cancellationCheck() }
            guard scan.nodes.indices.contains(root.nodeID) else { continue }
            let node = scan.nodes[root.nodeID]
            let ancestry = ancestry(for: root.nodeID, in: scan)
            let projectID: Int?
            if root.category == .gitRepositories {
                projectID = node.parent
            } else {
                projectID = isShared(root.category) ? nil : ancestry.first(where: markerDirectories.contains)
            }
            let tool = toolName(
                for: root.category,
                nodeName: node.name,
                ancestry: ancestry,
                projectMarkers: projectID.flatMap { markerNamesByDirectory[$0] } ?? [],
                scan: scan
            )
            let finding = DeveloperFinding(
                nodeID: root.nodeID,
                category: root.category,
                allocatedBytes: root.allocatedBytes,
                projectID: projectID,
                tool: tool,
                evidence: "Matched \(node.name) using a metadata path rule; file contents were not read.",
                consequence: consequence(for: root.category),
                confidence: confidence(for: root.category),
                lastModified: node.modified
            )
            findings.append(finding)

            if let projectID {
                var accumulator = projectAccumulators[projectID, default: ProjectAccumulator()]
                accumulator.allocatedBytes = reportSaturatingAdd(accumulator.allocatedBytes, root.allocatedBytes)
                accumulator.categoryBytes[root.category] = reportSaturatingAdd(
                    accumulator.categoryBytes[root.category] ?? 0,
                    root.allocatedBytes
                )
                accumulator.findings.append(finding)
                projectAccumulators[projectID] = accumulator
            }
        }

        findings.sort { left, right in
            if left.allocatedBytes != right.allocatedBytes { return left.allocatedBytes > right.allocatedBytes }
            return left.id < right.id
        }

        let projects = projectAccumulators.compactMap { projectID, accumulator -> DeveloperProject? in
            guard scan.nodes.indices.contains(projectID) else { return nil }
            let findingIDs = accumulator.findings.sorted { left, right in
                if left.allocatedBytes != right.allocatedBytes { return left.allocatedBytes > right.allocatedBytes }
                return left.id < right.id
            }.map(\.id)
            return DeveloperProject(
                nodeID: projectID,
                name: scan.nodes[projectID].name,
                allocatedBytes: accumulator.allocatedBytes,
                categoryBytes: accumulator.categoryBytes,
                findingIDs: findingIDs
            )
        }.sorted { left, right in
            if left.allocatedBytes != right.allocatedBytes { return left.allocatedBytes > right.allocatedBytes }
            return left.id < right.id
        }

        return DeveloperReport(findings: findings, projects: projects)
    }

    private static func attributedRoots(from groups: [DeveloperGroup], nodeCount: Int) -> [Int: AttributedRoot] {
        var result: [Int: AttributedRoot] = [:]
        for group in groups {
            for nodeID in group.rootIDs {
                guard (0..<nodeCount).contains(nodeID),
                      let bytes = group.rootAllocatedBytes[nodeID],
                      result[nodeID] == nil else { continue }
                result[nodeID] = AttributedRoot(nodeID: nodeID, category: group.category, allocatedBytes: bytes)
            }
        }
        return result
    }

    private static func markerCanDefineProject(
        _ node: DiskNode,
        artifactRootID: Int?,
        roots: [Int: AttributedRoot]
    ) -> Bool {
        let name = node.name.lowercased()
        guard projectMarkerNames.contains(name), !node.isSymlink else { return false }
        guard name == ".git" || !node.isDirectory else { return false }
        // A temporary fallback can contain a real worktree. Other recognized
        // artifact subtrees (such as node_modules) must not create projects
        // from their own vendored manifests.
        if let artifactRootID,
           roots[artifactRootID]?.category != .temporary,
           !(name == ".git" && roots[artifactRootID]?.category == .gitRepositories) {
            return false
        }
        return true
    }

    /// Starts at the finding root so this is O(depth) per finding, rather
    /// than repeatedly searching all scanned nodes from a UI row.
    private static func ancestry(for nodeID: Int, in scan: ScanResult) -> [Int] {
        var result: [Int] = []
        var current = scan.nodes[nodeID].parent
        while let id = current, scan.nodes.indices.contains(id) {
            result.append(id)
            current = scan.nodes[id].parent
        }
        return result
    }

    private static func isShared(_ category: DeveloperCategory) -> Bool {
        switch category {
        case .claudeSessions, .codexSessions, .aiCaches, .packageCaches, .containerStorage, .modelCaches,
             .installers, .oldDownloads:
            return true
        case .gitRepositories, .nodeModules, .pythonEnvironments, .installedModules, .buildOutputs, .temporary:
            return false
        }
    }

    private static func toolName(
        for category: DeveloperCategory,
        nodeName: String,
        ancestry: [Int],
        projectMarkers: Set<String>,
        scan: ScanResult
    ) -> String {
        let names = ([nodeName] + ancestry.compactMap { scan.nodes.indices.contains($0) ? scan.nodes[$0].name : nil })
            .map { $0.lowercased() }
        switch category {
        case .claudeSessions: return "Claude"
        case .codexSessions: return "Codex"
        case .aiCaches: return "AI cache"
        case .gitRepositories: return "Git"
        case .nodeModules: return "Node.js"
        case .pythonEnvironments: return "Python"
        case .installedModules:
            if projectMarkers.contains("composer.json") { return "Composer" }
            if projectMarkers.contains("gemfile") { return "Bundler" }
            if names.contains("pods") { return "CocoaPods" }
            if names.contains("bower_components") { return "Bower" }
            if names.contains("vendor") { return "Composer or Bundler" }
            return "Installed modules"
        case .packageCaches:
            if names.contains("homebrew") { return "Homebrew" }
            if names.contains("ccache") { return "ccache" }
            if names.contains("sccache") { return "sccache" }
            if names.contains(".terraform") { return "Terraform" }
            if names.contains("bun") || names.contains(".bun") { return "Bun" }
            if names.contains(".npm") || names.contains("npm") { return "npm" }
            if names.contains("pnpm") || names.contains(".pnpm-store") { return "pnpm" }
            if names.contains("yarn") || names.contains(".yarn") { return "Yarn" }
            if names.contains("pip") { return "pip" }
            if names.contains("uv") { return "uv" }
            if names.contains(".cargo") { return "Cargo" }
            if names.contains(".gradle") { return "Gradle" }
            if names.contains(".m2") { return "Maven" }
            if names.contains(".nuget") { return "NuGet" }
            if names.contains("go") { return "Go" }
            return "Package cache"
        case .containerStorage:
            if names.contains("com.docker.docker") || names.contains("group.com.docker") { return "Docker" }
            if names.contains("com.podman.desktop") || names.contains("containers") { return "Podman" }
            if names.contains("com.utmapp.utm") { return "UTM" }
            return "Container or VM storage"
        case .modelCaches:
            if names.contains(".ollama") { return "Ollama" }
            if names.contains("huggingface") { return "Hugging Face" }
            if names.contains("torch") { return "PyTorch" }
            return "Model cache"
        case .buildOutputs:
            if names.contains("deriveddata") { return "Xcode" }
            if names.contains(".build") { return "SwiftPM" }
            if names.contains(".next") { return "Next.js" }
            if names.contains(".nuxt") { return "Nuxt" }
            if names.contains(".svelte-kit") { return "SvelteKit" }
            if names.contains(".angular") { return "Angular" }
            if names.contains(".dart_tool") { return "Dart" }
            if names.contains("target") {
                if projectMarkers.contains("cargo.toml") { return "Cargo" }
                if projectMarkers.contains("pom.xml") { return "Maven" }
                if projectMarkers.contains("build.gradle") || projectMarkers.contains("build.gradle.kts") { return "Gradle" }
            }
            return "Build tool"
        case .temporary: return "Temporary storage"
        case .installers:
            switch (nodeName as NSString).pathExtension.lowercased() {
            case "dmg": return "Disk image"
            case "pkg", "mpkg": return "Installer package"
            case "xip": return "Signed archive"
            case "iso": return "ISO image"
            case "ipsw": return "Device restore image"
            default: return "Installer"
            }
        case .oldDownloads: return "Old download"
        }
    }

    private static func consequence(for category: DeveloperCategory) -> String {
        switch category {
        case .claudeSessions:
            return "Claude session history may be valuable context; do not auto-delete."
        case .codexSessions:
            return "Codex session history may be valuable context; do not auto-delete."
        case .containerStorage:
            return "Container and VM storage can hold images, volumes, and machine state; do not auto-delete."
        case .gitRepositories:
            return "Git metadata can contain branches, objects, stashes and recovery history that are not available elsewhere. Do not remove it as cleanup."
        case .nodeModules, .installedModules:
            return "Removing dependencies can break running tools until reinstalled. Restore them only if dependency definitions, required versions and package sources remain available; local changes may be lost."
        case .pythonEnvironments:
            return "Removing this environment breaks tools that use it. Recreate it only if its dependency list, Python version and package sources are available; custom packages and local changes may be lost."
        case .buildOutputs:
            return "Build outputs can usually be regenerated if source and required toolchains remain available. Review before cleanup."
        case .temporary:
            return "Temporary storage may contain unsaved work or active-process state; stop and review before cleanup."
        case .packageCaches:
            return "Package cache entries may be recreated by their tool, but verify source and remote availability before cleanup."
        case .aiCaches:
            return "AI cache data may be recreated, but verify the tool can restore it before cleanup."
        case .modelCaches:
            return "Models may need to be downloaded again; verify remote availability before cleanup."
        case .installers:
            return "Removing an installer does not remove an installed app. Installers can usually be downloaded again, but version availability is not guaranteed."
        case .oldDownloads:
            return "Age is the only evidence here; some downloads are the only copy of a file. Review contents before cleanup."
        }
    }

    private static func confidence(for category: DeveloperCategory) -> String {
        switch category {
        case .buildOutputs, .temporary, .oldDownloads: return "Medium"
        default: return "High"
        }
    }
}

public struct DeveloperFinding: Identifiable, Sendable {
    public let id: Int
    public let category: DeveloperCategory
    public let allocatedBytes: Int64
    public let projectID: Int?
    public let tool: String
    public let evidence: String
    public let consequence: String
    public let confidence: String
    /// Metadata modification date of the matched root, not an activity signal.
    public let lastModified: Date

    public init(
        nodeID: Int,
        category: DeveloperCategory,
        allocatedBytes: Int64,
        projectID: Int?,
        tool: String,
        evidence: String,
        consequence: String,
        confidence: String,
        lastModified: Date
    ) {
        self.id = nodeID
        self.category = category
        self.allocatedBytes = allocatedBytes
        self.projectID = projectID
        self.tool = tool
        self.evidence = evidence
        self.consequence = consequence
        self.confidence = confidence
        self.lastModified = lastModified
    }
}

public struct DeveloperProject: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let allocatedBytes: Int64
    public let categoryBytes: [DeveloperCategory: Int64]
    public let findingIDs: [Int]

    public init(
        nodeID: Int,
        name: String,
        allocatedBytes: Int64,
        categoryBytes: [DeveloperCategory: Int64],
        findingIDs: [Int]
    ) {
        self.id = nodeID
        self.name = name
        self.allocatedBytes = allocatedBytes
        self.categoryBytes = categoryBytes
        self.findingIDs = findingIDs
    }
}

private struct AttributedRoot {
    let nodeID: Int
    let category: DeveloperCategory
    let allocatedBytes: Int64
}

private struct ProjectAccumulator {
    var allocatedBytes: Int64 = 0
    var categoryBytes: [DeveloperCategory: Int64] = [:]
    var findings: [DeveloperFinding] = []
}

private let projectMarkerNames: Set<String> = [
    "package.json", "cargo.toml", "pyproject.toml", "go.mod", "package.swift", "pom.xml", "build.gradle", "build.gradle.kts",
    "composer.json", "gemfile", "podfile", ".git"
]

private func reportSaturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? Int64.max : Int64.min) : value
}
