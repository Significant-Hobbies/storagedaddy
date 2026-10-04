import DiskCore
import SwiftUI

/// A review-only selection: every copy is kept until the owner explicitly changes it.
/// Invalid evidence fails closed; the caller still owns filesystem preflight.
struct DuplicateReviewSelection {
    let memberIDs: [Int]
    private(set) var survivorIDs: Set<Int>
    let isValid: Bool
    private let allocations: [Int: Int64]

    init(group: DuplicateGroup, scan: ScanResult) {
        memberIDs = group.nodeIDs
        survivorIDs = Set(group.nodeIDs)
        isValid = group.nodeIDs.count >= 2 && Set(group.nodeIDs).count == group.nodeIDs.count &&
            group.nodeIDs.allSatisfy { id in
                scan.nodes.indices.contains(id) && scan.nodes[id].id == id &&
                    scan.nodes[id].parent != nil && !scan.nodes[id].isDirectory &&
                    !scan.nodes[id].isSymlink && scan.nodes[id].allocatedBytes >= 0
            }
        allocations = isValid ? Dictionary(uniqueKeysWithValues: group.nodeIDs.map {
            ($0, scan.nodes[$0].allocatedBytes)
        }) : [:]
    }

    @discardableResult
    mutating func setSurvivor(_ id: Int, kept: Bool) -> Bool {
        guard isValid, memberIDs.contains(id) else { return false }
        if kept { survivorIDs.insert(id) }
        else {
            guard survivorIDs.count > 1 else { return false }
            survivorIDs.remove(id)
        }
        return true
    }

    var removalIDs: [Int] {
        guard isValid, !survivorIDs.isEmpty else { return [] }
        return memberIDs.filter { !survivorIDs.contains($0) }
    }

    /// Nil means an invalid allocation or overflow, never a reclaim promise.
    var allocatedUpperBound: Int64? {
        guard isValid else { return nil }
        var total: Int64 = 0
        for id in removalIDs {
            guard let bytes = allocations[id] else { return nil }
            let sum = total.addingReportingOverflow(bytes)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    var canStage: Bool { !removalIDs.isEmpty && allocatedUpperBound != nil }

    func stage(using callback: ([Int]) -> Void) {
        guard canStage else { return }
        callback(removalIDs)
    }
}

/// Owner supplies only results for `scan`, invalidates them on scan changes, and
/// routes `onStage` through ExplorerModel.stage() preflight. No file I/O occurs here.
struct DuplicateReviewView: View {
    let scan: ScanResult
    let groups: [DuplicateGroup]
    let isLoading: Bool
    let error: String?
    let onFind: () -> Void
    let onCancel: () -> Void
    let onStage: ([Int]) -> Void
    var hasSearched = false

    @State private var selectedGroupID: String?

    private var selectedGroup: DuplicateGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Duplicates").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Compare identical files. Choose which copies to keep before staging the others.")
                        .font(.subheadline).foregroundStyle(Tints.secondaryText)
                }
                Spacer(minLength: 8)
                if isLoading {
                    Button("Cancel", action: onCancel).buttonStyle(StorageButtonStyle())
                } else {
                    Button(hasSearched ? "Find again" : "Find duplicates", action: onFind)
                        .buttonStyle(StorageButtonStyle(prominent: true))
                }
            }
            if scan.skipped > 0 || !scan.errors.isEmpty {
                Label("The scan is incomplete. Results cover only files that could be inspected.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Tints.yellow)
            }
            if isLoading {
                statePanel("Checking file contents…", detail: "Reading full contents and comparing matching files byte for byte.") {
                    ProgressView().controlSize(.small).tint(Tints.mint)
                }
            } else if let error {
                statePanel("Duplicate check couldn’t finish", detail: error) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Tints.yellow)
                    Button("Try again", action: onFind).buttonStyle(StorageButtonStyle(prominent: true))
                }
            } else if !hasSearched {
                statePanel("Duplicates haven’t been checked", detail: "Run a content check for this scan. Nothing is selected for cleanup.") {
                    Image(systemName: "doc.on.doc").foregroundStyle(Tints.mint)
                }
            } else if groups.isEmpty {
                statePanel("No duplicates found", detail: "No identical copies were found among the eligible files in this scan.") {
                    Image(systemName: "checkmark.circle").foregroundStyle(Tints.mint)
                }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 760 {
                        HStack(alignment: .top, spacing: 18) {
                            groupList.frame(width: 240)
                            inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 14) {
                            groupList.frame(height: 150)
                            inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .padding(24).foregroundStyle(.white)
        .font(.system(size: 13, design: .rounded))
        .tint(Tints.mint)
        .background(Color.black)
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("\(groups.count.formatted()) identical \(groups.count == 1 ? "group" : "groups")")
                    .font(.caption).foregroundStyle(Tints.secondaryText).padding(.bottom, 4)
                ForEach(groups) { group in
                    Button { selectedGroupID = group.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(groupName(group)).fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                            Text("\(group.nodeIDs.count) copies · inspect to choose")
                                .font(.caption).foregroundStyle(Tints.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(selectedGroup?.id == group.id ? Tints.mint.opacity(0.14) : Color.white.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(selectedGroup?.id == group.id ? 0.5 : 0.12)))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Inspect \(groupName(group)), \(group.nodeIDs.count) copies")
                        .accessibilityAddTraits(selectedGroup?.id == group.id ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if let group = selectedGroup {
            DuplicateGroupInspector(scan: scan, group: group, onStage: onStage)
                .id(group.id)
        }
    }

    private func groupName(_ group: DuplicateGroup) -> String {
        guard let id = group.nodeIDs.first, scan.nodes.indices.contains(id) else { return "Unavailable group" }
        return scan.nodes[id].name
    }

    private func statePanel<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            content()
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(Tints.secondaryText).multilineTextAlignment(.center)
                .textSelection(.enabled).frame(maxWidth: 460)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DuplicateGroupInspector: View {
    let scan: ScanResult
    let group: DuplicateGroup
    let onStage: ([Int]) -> Void
    @State private var selection: DuplicateReviewSelection

    init(scan: ScanResult, group: DuplicateGroup, onStage: @escaping ([Int]) -> Void) {
        self.scan = scan; self.group = group; self.onStage = onStage
        _selection = State(initialValue: DuplicateReviewSelection(group: group, scan: scan))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose copies to keep").font(.title3.weight(.semibold))
            Label("Full content SHA-256 + exact byte comparison", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(Tints.mint)
            Text("Keep at least one copy. All copies start kept; uncheck Keep to select a copy for cleanup.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            Divider().overlay(Tints.mint.opacity(0.18))
            if selection.isValid {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(group.nodeIDs, id: \.self) { id in memberRow(id) }
                    }
                }.frame(maxHeight: .infinity)
            } else {
                Text("This group no longer matches the scan. Find duplicates again before staging.")
                    .foregroundStyle(Tints.yellow)
                Spacer()
            }
            Divider().overlay(Tints.mint.opacity(0.18))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { estimate; Spacer(); stageButton }
                VStack(alignment: .leading, spacing: 12) { estimate; stageButton }
            }
            Text("Upper bound only. APFS copies can share blocks. Space is released only after Trash is emptied; reclaim is not guaranteed.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
        }.padding(18)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.18)))
    }

    private var estimate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.allocatedUpperBound.map(DiskFormat.bytes) ?? "Unavailable")
                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Allocated upper bound · \(selection.removalIDs.count) selected for cleanup")
                .font(.caption).foregroundStyle(Tints.secondaryText)
        }
    }

    private var stageButton: some View {
        Button("Stage other copies") { selection.stage(using: onStage) }
            .buttonStyle(StorageButtonStyle(prominent: true)).disabled(!selection.canStage)
            .help("Send only the selected copies to cleanup review. Files are not moved by this action.")
    }

    private func memberRow(_ id: Int) -> some View {
        let node = scan.nodes[id]
        let path = scan.url(for: id).path
        let kept = selection.survivorIDs.contains(id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kept ? "doc" : "tray.and.arrow.down").foregroundStyle(kept ? Tints.mint : Tints.yellow)
                VStack(alignment: .leading, spacing: 5) {
                    Text(path.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥"))
                        .fontWeight(.medium).lineLimit(3).truncationMode(.middle).textSelection(.enabled).help(path)
                    Text("Logical \(DiskFormat.bytes(node.logicalBytes)) · Allocated \(DiskFormat.bytes(node.allocatedBytes))")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                    Text(kept ? "Kept" : "Selected for cleanup").font(.caption).foregroundStyle(kept ? Tints.mint : Tints.yellow)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Keep", isOn: Binding(get: { selection.survivorIDs.contains(id) }, set: {
                    selection.setSurvivor(id, kept: $0)
                })).toggleStyle(.checkbox)
                    .disabled(kept && selection.survivorIDs.count == 1)
                    .accessibilityLabel("Keep \(path)")
                    .help(kept && selection.survivorIDs.count == 1 ? "At least one copy must be kept" : "Keep this copy out of cleanup")
            }
        }.padding(12)
            .background(kept ? Color.black.opacity(0.4) : Tints.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}
