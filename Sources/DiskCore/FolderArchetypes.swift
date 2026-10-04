import Foundation

/// A folder's likely role, inferred from scan metadata. This does not establish
/// ownership, current use, recoverability or reclaimable bytes.
public enum FolderArchetype: String, Sendable {
    case project, gitMetadata, dependencies, buildOutputs, cache, models, virtualMachines
    case application, appData, personalFiles, systemStorage, agentHistory, unknown

    public var label: String {
        switch self {
        case .project: "Source project"
        case .gitMetadata: "Git repository metadata"
        case .dependencies: "Installed dependencies"
        case .buildOutputs: "Build output"
        case .cache: "Cache storage"
        case .models: "Model storage"
        case .virtualMachines: "Virtual machine / container storage"
        case .application: "Application bundle"
        case .appData: "Persistent app data"
        case .personalFiles: "Personal files"
        case .systemStorage: "System-managed storage"
        case .agentHistory: "AI conversation history"
        case .unknown: "Folder type unconfirmed"
        }
    }

    public var guidance: String {
        switch self {
        case .project:
            "Keep source, local changes and configuration. Review dependencies and build outputs separately; inspect Git status and unpublished work before removing a whole project. A manifest does not prove the project is abandoned."
        case .gitMetadata:
            "This can hold repository history, branches, worktree links and unpublished commits. Inspect Git status, worktrees and remotes before cleanup; deleting Git metadata can lose history and break the checkout."
        case .dependencies:
            "Check the parent project's manifest, lockfile and local changes. Dependencies are often reinstallable, but required versions or offline packages may be unavailable. Stop tools using them before cleanup."
        case .buildOutputs:
            "Check the owning project and build inputs, then prefer its clean command. The folder may contain exports or hand-edited files; its name does not prove every item can be rebuilt."
        case .cache:
            "Prefer the owning tool's cache cleanup after stopping it. Some cached data is needed offline or cannot be downloaded again. A cache location does not establish that the data is unused."
        case .models:
            "Review model versions through the owning tool. Downloads may be replaceable, while fine-tunes and local checkpoints may be original work. Removing models can disable offline inference or require large downloads."
        case .virtualMachines:
            "Review images, machines and volumes in the owning app. Virtual disks can contain databases and original work. Deleting files inside the backing store can damage it; deleting guest data may require the app's compaction process before host disk space falls."
        case .application:
            "Use the app's uninstaller or review the complete app footprint. Removing a bundle does not account for support data elsewhere, and editing its contents can break the app."
        case .appData:
            "This location can hold databases, documents, settings and shared app state. Identify the owning app and use its storage controls; do not treat the whole folder as a cache."
        case .personalFiles:
            "Review original files and backups individually. Age and size do not establish that a document, photo, download or archive is unused. Check cloud sync and whether another copy exists before cleanup."
        case .systemStorage:
            "Use macOS or the owning system tool's storage controls. Protected folders and APFS volumes may not expand into ordinary files; missing access is not evidence of unused space."
        case .agentHistory:
            "Archive conversations before cleanup. Reinstalling the agent cannot regenerate prompts and replies, and a conversation export may not restore a resumable session."
        case .unknown:
            "The scanned metadata does not establish this folder's role. Inspect its owner and contents before deciding what can be regenerated or removed."
        }
    }
}

public struct FolderAssessment: Sendable {
    public let archetype: FolderArchetype
    public let evidence: String
    public let coverage: String

    public var explanation: String {
        "\(archetype.label). \(evidence) \(archetype.guidance) \(coverage)"
    }
}

public enum FolderArchetypes {
    /// Uses only paths, names and flags already present in the scan. No file
    /// contents, extra traversal or agent invocation is needed on selection.
    public static func assess(_ scan: ScanResult, folderID: Int, category: DeveloperCategory? = nil) -> FolderAssessment? {
        guard scan.nodes.indices.contains(folderID) else { return nil }
        let node = scan.nodes[folderID]
        guard node.isDirectory, !node.isSymlink else { return nil }
        let rawPath = scan.url(for: folderID).standardizedFileURL.path
        let path = rawPath == "/System/Volumes/Data" ? "/" : rawPath.hasPrefix("/System/Volumes/Data/") ? String(rawPath.dropFirst("/System/Volumes/Data".count)) : rawPath
        let parts = path.split(separator: "/").map(String.init)
        let lower = parts.map { $0.lowercased() }
        let name = node.name.lowercased()
        let markers = projectMarkers(in: node, scan: scan)
        let parentMarkers = node.parent.flatMap { scan.nodes.indices.contains($0) ? projectMarkers(in: scan.nodes[$0], scan: scan) : nil } ?? []
        let homeRelative = parts.count >= 3 && parts[0] == "Users" ? Array(parts.dropFirst(2)) : []
        let homeLower = homeRelative.map { $0.lowercased() }

        func assessment(_ type: FolderArchetype, _ evidence: String) -> FolderAssessment {
            let coverage: String
            if node.isContentsUnreadable == true {
                coverage = "Contents could not be read. The role is inferred from the path; neither contents nor a zero size have been verified."
            } else if node.isScanIncomplete == true {
                coverage = "This scan is incomplete. Displayed bytes cover only scanned entries; hidden contents may change the assessment."
            } else if node.isScanIncomplete == nil {
                coverage = "Folder-level scan completeness was not recorded."
            } else {
                coverage = "Recognition does not measure whether the folder is currently in use."
            }
            return FolderAssessment(archetype: type, evidence: evidence, coverage: coverage)
        }

        // Persistent stores take precedence over generic directory-name hints.
        let vmOwners: Set<String> = ["huaq24hbr6.dev.orbstack", "orbstack", "com.docker.docker", "group.com.docker", "com.podman.desktop", "com.utmapp.utm", "com.parallels.desktop", "com.vmware.fusion"]
        let inAppStore = homeLower.starts(with: ["library", "group containers"]) || homeLower.starts(with: ["library", "containers"]) || homeLower.starts(with: ["library", "application support"])
        if (inAppStore && homeLower.dropFirst(2).first.map(vmOwners.contains) == true) || homeLower.first == ".orbstack" || lower.contains(where: { $0.hasSuffix(".utm") || $0.hasSuffix(".pvm") || $0.hasSuffix(".vmwarevm") }) {
            return assessment(.virtualMachines, "Matched a known virtualization app location or virtual-machine bundle path.")
        }
        if lower.contains(where: { $0.hasSuffix(".app") }) {
            return assessment(.application, "The path is in a folder with an .app bundle suffix; bundle contents have not been validated.")
        }
        if path == "/System" || path.hasPrefix("/System/") || path == "/private/var/vm" || path.hasPrefix("/private/var/vm/") || path == "/var/vm" || path.hasPrefix("/var/vm/") {
            return assessment(.systemStorage, "Matched a system-managed path.")
        }
        if homeLower.starts(with: [".codex", "sessions"]) || homeLower.starts(with: [".codex", "archived_sessions"]) || homeLower.starts(with: [".claude", "projects"]) {
            return assessment(.agentHistory, "Matched an agent's conversation-storage path.")
        }
        if category == .containerStorage { return assessment(.virtualMachines, "The developer scan recognized container storage in this subtree.") }
        let modelTools: Set<String> = ["huggingface", "torch", "whisper", "transformers", "diffusers", "sentence-transformers"]
        let inModelCache = (homeLower.first == ".cache" && homeLower.dropFirst().first.map(modelTools.contains) == true) || (homeLower.starts(with: ["library", "caches"]) && homeLower.dropFirst(2).first.map(modelTools.contains) == true)
        if category == .modelCaches || homeLower.starts(with: [".ollama", "models"]) || inModelCache {
            return assessment(.models, "Matched a known model-store location or the developer scan's model category.")
        }
        if category == .gitRepositories || lower.contains(".git") {
            return assessment(.gitMetadata, "Matched a .git path component or the developer scan's Git metadata category; repository state has not been read.")
        }
        if category == .nodeModules || category == .installedModules || category == .pythonEnvironments || name == "node_modules" || name == "site-packages" || [".venv", "venv", ".tox", ".nox"].contains(name) {
            return assessment(.dependencies, "Matched a dependency/environment directory name or developer category; reinstallability has not been verified.")
        }
        if homeLower.starts(with: ["library", "caches"]) || homeLower.first == ".cache" || category == .packageCaches || category == .aiCaches {
            return assessment(.cache, "Matched a cache location or the developer scan's cache category.")
        }
        if inAppStore {
            return assessment(.appData, "Matched a user Library app-support, sandbox or shared-container location.")
        }
        if [".build", ".next", ".nuxt", ".svelte-kit", ".angular", ".dart_tool", "dist", "build", "target"].contains(name), !parentMarkers.isEmpty {
            return assessment(.buildOutputs, "Matched \(node.name) beside project markers: \(parentMarkers.joined(separator: ", ")).")
        }
        if homeLower.starts(with: ["library", "developer", "xcode", "deriveddata"]) {
            return assessment(.buildOutputs, "Matched Xcode's DerivedData location.")
        }
        if !markers.isEmpty {
            return assessment(.project, "Observed immediate project markers: \(markers.joined(separator: ", ")). Recognition uses filename metadata; manifest contents have not been read. Git review evidence is checked separately.")
        }
        if let first = homeLower.first, ["desktop", "documents", "downloads", "pictures", "movies", "music"].contains(first) {
            return assessment(.personalFiles, "Matched a personal-files location; no more specific role was confirmed.")
        }
        return assessment(.unknown, "No supported folder markers or known storage location matched.")
    }

    private static func projectMarkers(in node: DiskNode, scan: ScanResult) -> [String] {
        let manifests: Set<String> = ["package.json", "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "composer.json", "gemfile", "podfile", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "cmakelists.txt"]
        return node.children.compactMap { id -> String? in
            guard scan.nodes.indices.contains(id) else { return nil }
            let child = scan.nodes[id]
            guard !child.isSymlink else { return nil }
            let name = child.name.lowercased()
            if name == ".git" || (!child.isDirectory && manifests.contains(name)) { return child.name }
            return nil
        }.sorted()
    }
}
