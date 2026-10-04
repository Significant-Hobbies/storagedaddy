import Foundation

/// Supplied by the integration's bounded, local probe. This module performs no
/// filesystem access and starts no processes. IDs must refer to this exact scan.
public enum ProjectPurgeGitEvidence: Sendable {
    case verified(trackedNodeIDs: Set<Int>, checkoutRootIDs: Set<Int>)
    case unavailable
    case failed(String)
}

public struct ProjectPurgeProbe: Sendable {
    public let git: ProjectPurgeGitEvidence
    /// Explicit, independently reviewed restoration evidence per artifact root.
    /// Manifest/path names alone must never populate this dictionary.
    public let rebuildability: [Int: String]
    /// Plans explicitly acknowledged by the owner, not independently proven
    /// restoration. Integration owns persistence and acknowledgement provenance.
    public let recoveryPlans: [Int: String]

    public init(git: ProjectPurgeGitEvidence, rebuildability: [Int: String] = [:], recoveryPlans: [Int: String] = [:]) {
        self.git = git
        self.rebuildability = rebuildability
        self.recoveryPlans = recoveryPlans
    }
}

public enum ProjectPurgeProtection: String, Sendable, CaseIterable {
    case incompleteScan = "Scan incomplete or skipped entries; review cannot verify this workspace."
    case unknownModification = "Workspace modified date is unknown; this is not last-used evidence."
    case recentModification = "Workspace modified within 7 days; batch proposal blocked."
    case unverifiedGit = "Git tracking evidence unavailable, failed or invalid; artifact remains unverified."
    case unprovenRebuildability = "Metadata candidate only; add an owner-reviewed recovery plan or verified restoration evidence."
    case deploymentKeypair = "Artifact contains a deployment keypair name; keep this subtree."
    case nestedCheckout = "Artifact contains Git metadata or a nested checkout/worktree; keep this subtree."
    case trackedFile = "Artifact contains a Git-tracked file; keep this subtree."
    case symlink = "Artifact contains a symbolic link; its contents cannot be verified from this scan."
    case workspaceRoot = "Project roots, checkout roots and Git metadata cannot be staged."
}

public struct ProjectPurgeArtifact: Identifiable, Sendable {
    public let finding: DeveloperFinding
    public let rebuildabilityEvidence: String?
    public let userReviewedRecoveryPlan: String?
    public let protections: [ProjectPurgeProtection]
    public var id: Int { finding.id }
    public var allocatedBytes: Int64 { finding.allocatedBytes }
    public var canStage: Bool { protections.isEmpty }
}

public struct ProjectPurgeRecord: Identifiable, Sendable {
    public let project: DeveloperProject
    public let signatures: [String]
    /// Newest metadata modification date anywhere beneath this workspace,
    /// including source, artifacts, Git metadata and nested workspaces.
    public let newestModified: Date?
    public let protections: [ProjectPurgeProtection]
    public let artifacts: [ProjectPurgeArtifact]
    public var id: Int { project.id }
    public var candidateBytes: Int64 { project.allocatedBytes }
    public var stageableArtifactIDs: Set<Int> { Set(artifacts.filter(\.canStage).map(\.id)) }
}

public enum ProjectPurgeSort: String, CaseIterable, Sendable {
    case size = "Largest first"
    case age = "Oldest modified first"
}

public enum ProjectPurgeReview {
    public static let minimumModifiedAge: TimeInterval = 7 * 24 * 60 * 60

    /// Uses existing classification and report attribution. Only ownership is
    /// expanded here; no new artifact classifier and no content reads.
    public static func build(
        scan: ScanResult,
        report: DeveloperReport,
        probes: [Int: ProjectPurgeProbe] = [:],
        now: Date = Date()
    ) -> [ProjectPurgeRecord] {
        build(scan: scan, report: report, probes: probes, now: now, cancellationCheck: {})
    }

    /// Linear metadata aggregation; checkpoints also cover sparse probe walks
    /// and sorting. Cancellation throws without publishing a partial review.
    public static func build(
        scan: ScanResult,
        report: DeveloperReport,
        probes: [Int: ProjectPurgeProbe] = [:],
        now: Date = Date(),
        cancellationCheck: () throws -> Void
    ) rethrows -> [ProjectPurgeRecord] {
        try cancellationCheck()
        // Scanner IDs are indices, with parents before children. Fail closed
        // on foreign/malformed trees instead of following potentially cyclic IDs.
        guard !scan.nodes.isEmpty else { return [] }
        for (index, node) in scan.nodes.enumerated() {
            if index & 255 == 0 { try cancellationCheck() }
            guard node.id == index, (index == 0 ? node.parent == nil :
                node.parent.map { $0 >= 0 && $0 < index && scan.nodes[$0].isDirectory } == true) else { return [] }
        }

        var artifactRoots = Set<Int>()
        for (index, finding) in report.findings.enumerated() {
            if index & 255 == 0 { try cancellationCheck() }
            if finding.category != .temporary { artifactRoots.insert(finding.id) }
        }
        var insideArtifact = [Bool](repeating: false, count: scan.nodes.count)
        var markers: [Int: Set<String>] = [:]
        var unity: [Int: Set<String>] = [:]
        for node in scan.nodes {
            if node.id & 255 == 0 { try cancellationCheck() }
            let inherited = node.parent.map { insideArtifact[$0] } ?? false
            insideArtifact[node.id] = inherited || artifactRoots.contains(node.id)
            guard let parent = node.parent, !node.isSymlink, !inherited else { continue }
            let name = node.name.lowercased()
            if name == ".git" {
                markers[parent, default: []].insert(name)
            } else if !insideArtifact[node.id] {
                if node.isDirectory {
                    if name == "assets" || name == "projectsettings" {
                        unity[parent, default: []].insert(name)
                    }
                    if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                        markers[parent, default: []].insert(name)
                    }
                } else if fileMarkers.contains(name) || [".uproject", ".tf", ".csproj", ".fsproj", ".sln"].contains(where: name.hasSuffix) {
                    markers[parent, default: []].insert(name)
                }
            }
        }
        for (id, names) in unity {
            try cancellationCheck()
            if names == ["assets", "projectsettings"] {
                markers[id, default: []].insert("Assets + ProjectSettings")
            }
        }

        let count = scan.nodes.count
        var newest = [Date?](repeating: nil, count: count)
        var unknown = [Bool](repeating: false, count: count)
        var nearestProject = [Int?](repeating: nil, count: count)
        // Compact aggregate flags: keypair, checkout, symlink. No ancestor
        // arrays, recursive walks or per-node sets are allocated in these passes.
        var subtreeFlags = [UInt8](repeating: 0, count: count)
        var findings: [Int: [DeveloperFinding]] = [:]
        for node in scan.nodes {
            if node.id & 255 == 0 { try cancellationCheck() }
            nearestProject[node.id] = markers[node.id] != nil ? node.id : node.parent.flatMap { nearestProject[$0] }
            unknown[node.id] = node.modified == .distantPast || !node.modified.timeIntervalSince1970.isFinite || node.isSymlink
            if node.modified != .distantPast, node.modified.timeIntervalSince1970.isFinite { newest[node.id] = node.modified }
            if isKeypairName(node.name) { subtreeFlags[node.id] |= 1 }
            if [".git", ".worktrees", "worktrees"].contains(node.name.lowercased()) { subtreeFlags[node.id] |= 2 }
            if node.isSymlink { subtreeFlags[node.id] |= 4 }
        }
        for id in scan.nodes.indices.reversed() {
            if id & 255 == 0 { try cancellationCheck() }
            guard let parent = scan.nodes[id].parent else { continue }
            if let modified = newest[id] { newest[parent] = max(newest[parent] ?? .distantPast, modified) }
            unknown[parent] = unknown[parent] || unknown[id]
            subtreeFlags[parent] |= subtreeFlags[id]
        }
        for (index, finding) in report.findings.enumerated() {
            if index & 255 == 0 { try cancellationCheck() }
            guard artifactCategories.contains(finding.category) else { continue }
            guard scan.nodes.indices.contains(finding.id),
                  let parent = scan.nodes[finding.id].parent,
                  let owner = nearestProject[parent] else { continue }
            findings[owner, default: []].append(finding)
        }

        // Sparse injected evidence can walk the validated parent chain. Walks
        // are iterative, capped by node count and checkpointed every 256 steps.
        func belongs(_ id: Int, to owner: Int) throws -> Bool {
            guard scan.nodes.indices.contains(id) else { return false }
            var current: Int? = id
            var steps = 0
            while let next = current, steps < count {
                if steps & 255 == 0 { try cancellationCheck() }
                if next == owner { return true }
                current = scan.nodes[next].parent; steps += 1
            }
            return false
        }
        func addGitFlag(_ flag: ProjectPurgeProtection, from id: Int, to flags: inout [Int: Set<ProjectPurgeProtection>]) throws {
            var current: Int? = id
            var steps = 0
            while let next = current, steps < count {
                if steps & 255 == 0 { try cancellationCheck() }
                if artifactRoots.contains(next) { flags[next, default: []].insert(flag) }
                current = scan.nodes[next].parent; steps += 1
            }
        }

        let incomplete = scan.skipped > 0 || !scan.errors.isEmpty ||
            !(scan.incompleteEvidence ?? []).isEmpty || scan.incompleteEvidenceTruncated == true
        var records: [ProjectPurgeRecord] = []
        for owner in markers.keys {
            try cancellationCheck()
            var workspaceProtections: [ProjectPurgeProtection] = []
            if incomplete { workspaceProtections.append(.incompleteScan) }
            if unknown[owner] || newest[owner] == nil { workspaceProtections.append(.unknownModification) }
            if let modified = newest[owner], now.timeIntervalSince(modified) < minimumModifiedAge {
                workspaceProtections.append(.recentModification)
            }
            let probe = probes[owner]
            var tracked = Set<Int>(), checkouts = Set<Int>()
            var verified = false
            if case let .verified(trackedIDs, checkoutIDs) = probe?.git {
                verified = true
                for id in trackedIDs {
                    if try !belongs(id, to: owner) { verified = false; break }
                }
                if verified {
                    for id in checkoutIDs {
                        if try !belongs(id, to: owner) { verified = false; break }
                    }
                }
                if verified { tracked = trackedIDs; checkouts = checkoutIDs }
            }
            if !verified { workspaceProtections.append(.unverifiedGit) }
            var gitFlags: [Int: Set<ProjectPurgeProtection>] = [:]
            for id in tracked {
                try addGitFlag(.trackedFile, from: id, to: &gitFlags)
            }
            for id in checkouts {
                try addGitFlag(.nestedCheckout, from: id, to: &gitFlags)
            }
            var artifacts: [ProjectPurgeArtifact] = []
            for finding in findings[owner] ?? [] {
                try cancellationCheck()
                var protections = workspaceProtections
                let restoration = probe?.rebuildability[finding.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let plan = probe?.recoveryPlans[finding.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if restoration?.isEmpty != false, plan?.isEmpty != false { protections.append(.unprovenRebuildability) }
                let node = scan.nodes[finding.id]
                let isProject = markers[finding.id] != nil
                let isGit = node.name.lowercased() == ".git"
                if isProject || !node.isDirectory || isGit || checkouts.contains(finding.id) {
                    protections.append(.workspaceRoot)
                }
                var flags = Set<ProjectPurgeProtection>()
                if subtreeFlags[finding.id] & 1 != 0 { flags.insert(.deploymentKeypair) }
                if subtreeFlags[finding.id] & 2 != 0 { flags.insert(.nestedCheckout) }
                if subtreeFlags[finding.id] & 4 != 0 { flags.insert(.symlink) }
                flags.formUnion(gitFlags[finding.id] ?? [])
                for flag in ProjectPurgeProtection.allCases where flags.contains(flag) { protections.append(flag) }
                let attributed = DeveloperFinding(nodeID: finding.id, category: finding.category,
                    allocatedBytes: finding.allocatedBytes, projectID: owner, tool: finding.tool,
                    evidence: finding.evidence, consequence: finding.consequence,
                    confidence: finding.confidence, lastModified: finding.lastModified)
                artifacts.append(ProjectPurgeArtifact(finding: attributed, rebuildabilityEvidence: restoration,
                    userReviewedRecoveryPlan: plan?.isEmpty == false ? plan : nil, protections: protections))
            }
            try artifacts.sort {
                try cancellationCheck()
                if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
                return $0.id < $1.id
            }
            // Preserve original findings/bytes, replacing only project ownership.
            var categoryBytes: [DeveloperCategory: Int64] = [:]
            var total: Int64 = 0
            for artifact in artifacts {
                try cancellationCheck()
                total = adding(total, artifact.allocatedBytes)
                categoryBytes[artifact.finding.category] = adding(categoryBytes[artifact.finding.category] ?? 0, artifact.allocatedBytes)
            }
            let project = DeveloperProject(nodeID: owner, name: scan.nodes[owner].name,
                allocatedBytes: total, categoryBytes: categoryBytes, findingIDs: artifacts.map(\.id))
            records.append(ProjectPurgeRecord(project: project, signatures: (markers[owner] ?? []).sorted(),
                newestModified: unknown[owner] ? nil : newest[owner],
                protections: workspaceProtections, artifacts: artifacts))
        }
        try records.sort {
            try cancellationCheck()
            if $0.candidateBytes != $1.candidateBytes { return $0.candidateBytes > $1.candidateBytes }
            return $0.id < $1.id
        }
        try cancellationCheck()
        return records
    }

    public static func sorted(_ records: [ProjectPurgeRecord], by sort: ProjectPurgeSort) -> [ProjectPurgeRecord] {
        records.sorted {
            if sort == .age, $0.newestModified != $1.newestModified {
                // Unknown activity belongs after known dates, never "oldest".
                return ($0.newestModified ?? .distantFuture) < ($1.newestModified ?? .distantFuture)
            }
            if $0.candidateBytes != $1.candidateBytes { return $0.candidateBytes > $1.candidateBytes }
            return $0.id < $1.id
        }
    }

    /// Revalidate explicit selection at the callback boundary. Empty by default;
    /// roots and blocked findings cannot enter a proposal, even with stale IDs.
    public static func stageableSelection(_ selected: Set<Int>, in records: [ProjectPurgeRecord]) -> [Int] {
        let allowed = records.reduce(into: Set<Int>()) { $0.formUnion($1.stageableArtifactIDs) }
        return selected.intersection(allowed).sorted()
    }

    private static let artifactCategories: Set<DeveloperCategory> = [.nodeModules, .installedModules, .pythonEnvironments, .buildOutputs]
    // 28 exact file signatures plus typed suffixes and the two-directory Unity pair.
    private static let fileMarkers: Set<String> = [
        "package.json", "cargo.toml", "pyproject.toml", "go.mod", "package.swift", "pom.xml",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "composer.json", "gemfile", "podfile", "pubspec.yaml", "build.zig", "build.zig.zon",
        "requirements.txt", "setup.py", "setup.cfg", "pipfile", "cmakelists.txt", "meson.build",
        "mix.exs", "dune-project", "stack.yaml", "cabal.project", "project.clj", "deps.edn"
    ]

    private static func isKeypairName(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("keypair") || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "deploy_key", "deployment_key"].contains(name) ||
            [".pem", ".key", ".p12", ".pfx"].contains(where: name.hasSuffix)
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
