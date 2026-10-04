import Foundation

/// Reference metadata supplied by the caller. This component never inventories applications.
public struct AppLeftoverInventory: Sendable {
    public enum Completeness: String, Sendable { case complete, partial, unknown }
    public struct Application: Sendable {
        public let bundleID: String?
        public let names: [String]
        public init(bundleID: String?, names: [String]) {
            self.bundleID = bundleID; self.names = names
        }
    }
    public let applications: [Application]
    public let completeness: Completeness
    public let checkedAt: Date?
    public init(applications: [Application], completeness: Completeness, checkedAt: Date?) {
        self.applications = applications; self.completeness = completeness; self.checkedAt = checkedAt
    }
    public var supportsAbsenceEvidence: Bool {
        completeness == .complete && checkedAt != nil && !applications.isEmpty
            && applications.allSatisfy { $0.bundleID.map(AppLeftoverReview.isIdentifier) == true && !$0.names.isEmpty }
    }
}

public struct AppLeftoverRecord: Identifiable, Sendable {
    public enum Status: String, Sendable { case protected, unidentified, unattributedCandidate }
    public let id: Int
    public let path: String
    public let name: String
    public let category: String
    public let status: Status
    public let evidence: [String]
    public let reason: String
    /// Scanned allocated bytes only; not a prediction of space reclaimed.
    /// Nil when scan coverage is incomplete or the size is unavailable.
    public let allocatedUpperBound: Int64?
    public let unknowns: [String]
}

public struct AppLeftoverReviewResult: Sendable {
    public let records: [AppLeftoverRecord]
    public let inventoryCompleteness: AppLeftoverInventory.Completeness
    public let inventoryCheckedAt: Date?
    public let absenceEvidenceAvailable: Bool
    public let scanIncomplete: Bool
    public var candidates: [AppLeftoverRecord] { records.filter { $0.status == .unattributedCandidate } }
}

/// Pure metadata classification. Absence from a reference is never proof of an orphan or safe removal.
public enum AppLeftoverReview {
    public static let categories = ["Application Support", "Caches", "Preferences", "HTTPStorages",
                                    "WebKit", "Containers", "LaunchAgents", "Saved Application State"]

    /// `libraryRoot` is an explicit caller-owned Library scope, not discovered from the current home.
    public static func analyze(scan: ScanResult, inventory: AppLeftoverInventory,
                               libraryRoot: URL) -> AppLeftoverReviewResult {
        analyze(scan: scan, inventory: inventory, libraryRoot: libraryRoot, cancellationCheck: {})
    }
    public static func analyze(scan: ScanResult, inventory: AppLeftoverInventory,
                               libraryRoot: URL, cancellationCheck: () throws -> Void) rethrows -> AppLeftoverReviewResult {
        try cancellationCheck()
        let library = libraryRoot.standardizedFileURL.path
        let incomplete = scan.skipped > 0 || !scan.errors.isEmpty
            || !(scan.incompleteEvidence ?? []).isEmpty || scan.incompleteEvidenceTruncated == true
        var records: [AppLeftoverRecord] = []
        if libraryRoot.lastPathComponent == "Library" {
            for index in scan.nodes.indices {
                if index & 255 == 0 { try cancellationCheck() }
                // Only direct category children can be records. Avoid constructing
                // a full ancestry/path for every file in a whole-disk scan.
                if index != 0 {
                    guard let parent = scan.nodes[index].parent, scan.nodes.indices.contains(parent),
                          categories.contains(scan.nodes[parent].name) else { continue }
                }
                guard let path = metadataPath(index, scan: scan), !secretLooking(path),
                      let category = categories.first(where: {
                          URL(fileURLWithPath: path).deletingLastPathComponent().path == library + "/" + $0
                      }) else { continue }
                let node = scan.nodes[index]
                let identifier = stem(node.name, category: category).lowercased()
                var evidence: [String] = ["Direct root in Library/\(category); filename metadata only."]
                var status: AppLeftoverRecord.Status = .unidentified
                var reason = "Ownership is unidentified; review is not a cleanup recommendation."
                let matched = inventory.applications.first { app in
                    if let bundle = app.bundleID?.lowercased(), isIdentifier(bundle),
                       identifier == bundle || identifier.hasPrefix(bundle + ".") { return true }
                    let name = normalized(stem(node.name, category: category))
                    return !name.isEmpty && app.names.contains { normalized($0) == name }
                }
                if let matched {
                    status = .protected
                    reason = "Matches an installed application reference."
                    evidence.append("Installed reference: \(matched.bundleID ?? "no bundle ID"); names: \(matched.names.joined(separator: ", ")).")
                } else if reserved(identifier) || shared(identifier, inventory: inventory) {
                    status = .protected
                    reason = "OS, shared vendor, or ambiguous ownership must remain protected."
                } else if inventory.supportsAbsenceEvidence && isIdentifier(identifier) {
                    status = .unattributedCandidate
                    reason = "Identifier is absent from the supplied complete reference; ownership and removal safety remain unknown."
                    evidence.append("No exact bundle ID, dot-delimited subidentifier, or normalized full app-name match in the supplied inventory.")
                } else if !inventory.supportsAbsenceEvidence {
                    reason = "Installed-app reference is incomplete, unknown, empty, undated, or missing metadata; absence cannot be inferred."
                }
                var unknowns = ["Actual owner and current use are unverified.", "Removal safety and recoverability are unknown.",
                                "Apps outside the checked folders or installed later may be missing from this reference."]
                if incomplete { unknowns.append("Scan is incomplete; allocated upper bound is unknown.") }
                records.append(AppLeftoverRecord(id: index, path: path, name: node.name, category: category,
                    status: status, evidence: evidence, reason: reason,
                    allocatedUpperBound: incomplete || node.allocatedBytes < 0 ? nil : node.allocatedBytes,
                    unknowns: unknowns))
            }
        }
        return AppLeftoverReviewResult(records: records.sorted { $0.path < $1.path },
            inventoryCompleteness: inventory.completeness, inventoryCheckedAt: inventory.checkedAt,
            absenceEvidenceAvailable: inventory.supportsAbsenceEvidence, scanIncomplete: incomplete)
    }

    public static func isIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.first?.isLetter == true
                && part.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }
        }
    }

    private static func stem(_ name: String, category: String) -> String {
        var value = name
        for suffix in [".plist", ".savedState", ".app"] where value.lowercased().hasSuffix(suffix.lowercased()) {
            value = String(value.dropLast(suffix.count))
        }
        return value
    }
    private static func normalized(_ name: String) -> String {
        let value = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func reserved(_ identifier: String) -> Bool {
        if identifier.split(separator: ".").contains(where: { ["shared", "common", "group", "system"].contains(String($0)) }) { return true }
        return ["com.apple", "org.apple", "group", "system", "shared", "common", "com.microsoft", "com.google",
         "com.adobe", "com.amazon", "com.mozilla", "org.mozilla"].contains {
            identifier == $0 || identifier.hasPrefix($0 + ".")
        }
    }
    private static func shared(_ identifier: String, inventory: AppLeftoverInventory) -> Bool {
        let parts = identifier.split(separator: ".")
        guard parts.count >= 2 else { return false }
        let vendor = parts.prefix(2).joined(separator: ".")
        return inventory.applications.contains { app in
            guard let bundle = app.bundleID?.lowercased() else { return false }
            return bundle == vendor || bundle.hasPrefix(vendor + ".")
        }
    }
    private static func secretLooking(_ path: String) -> Bool {
        let value = path.lowercased()
        return ["secret", "credential", "keychain", "privatekey", "private-key", "private_key", "token", ".env", ".ssh", ".aws", ".gnupg", "kube", "apikey", "api-key", "api_key"].contains { value.contains($0) }
    }
    private static func metadataPath(_ index: Int, scan: ScanResult) -> String? {
        var current = index
        var seen = Set<Int>()
        var parts: [String] = []
        while true {
            guard scan.nodes.indices.contains(current), seen.insert(current).inserted else { return nil }
            let node = scan.nodes[current]
            guard node.id == current, !node.isSymlink else { return nil }
            if current == 0 {
                guard node.parent == nil, node.isDirectory else { return nil }
                break
            }
            guard !node.name.isEmpty, node.name != ".", node.name != "..", !node.name.contains("/"),
                  let parent = node.parent, scan.nodes.indices.contains(parent),
                  scan.nodes[parent].isDirectory, scan.nodes[parent].children.contains(current) else { return nil }
            parts.append(node.name); current = parent
        }
        return parts.reversed().reduce(URL(fileURLWithPath: scan.rootPath).standardizedFileURL) {
            $0.appendingPathComponent($1)
        }.path
    }
}
