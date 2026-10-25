import AppKit
import DiskCore
import SwiftUI

@MainActor final class TrashInventoryModel: ObservableObject {
    @Published private(set) var scan: ScanResult?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let trash: URL

    init(trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)) {
        self.trash = trash
    }

    var sizeLabel: String {
        if loading { return "Measuring…" }
        guard let scan else { return error == nil ? "Not measured" : "Size unavailable" }
        return DiskFormat.bytes(allocatedBytes) + (scan.skipped > 0 ? " · partial" : "")
    }

    var items: [DiskNode] {
        guard let scan, let root = scan.nodes.first else { return [] }
        return root.children.map { scan.nodes[$0] }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    var allocatedBytes: Int64 {
        items.reduce(0) { total, node in
            let (sum, overflow) = total.addingReportingOverflow(node.allocatedBytes)
            return overflow ? Int64.max : sum
        }
    }

    func refresh(excludedFolders: [String]) {
        task?.cancel()
        let version = UUID(); generation = version
        loading = true; error = nil; scan = nil
        task = Task {
            do {
                let result = try await DiskScanner.scan(root: trash, excludedFolders: excludedFolders)
                guard !Task.isCancelled, generation == version else { return }
                guard !result.nodes.isEmpty else {
                    error = "Home Trash is excluded by your folder settings."
                    loading = false
                    return
                }
                if result.incompleteEvidence?.contains(where: { $0.path == result.rootPath }) == true {
                    error = "Home Trash could not be read. Review it in Finder."
                    loading = false
                    return
                }
                scan = result
            } catch is CancellationError {
                return
            } catch {
                guard generation == version else { return }
                self.error = "Home Trash could not be read: \(error.localizedDescription)"
            }
            guard generation == version else { return }
            loading = false
        }
    }

    func cancel() {
        task?.cancel()
        generation = UUID()
        loading = false
    }
}

struct TrashInventoryView: View {
    @EnvironmentObject private var m: ExplorerModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var inventory = TrashInventoryModel()
    @State private var expanded = false
    private let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review or restore items in Finder. This measures the current user's Home Trash; other volumes are not included. Trash still uses space until emptied.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                HStack {
                    Button("Open Trash in Finder") { NSWorkspace.shared.open(trash) }
                    Button("Refresh Trash") { inventory.refresh(excludedFolders: m.excludedFolders) }
                        .disabled(inventory.loading)
                }
                if inventory.loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Measuring Trash…").foregroundStyle(Tints.secondaryText)
                        Spacer()
                        Button("Cancel", action: inventory.cancel)
                    }
                }
                if let error = inventory.error {
                    Text(error).font(.callout).foregroundStyle(Tints.yellow)
                    Text("If macOS blocks Trash access, enable storagedaddy in Full Disk Access to show its size. This grants broad file access.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                    Button("Open Full Disk Access Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                }
                if let scan = inventory.scan {
                    HStack {
                        Text("\(inventory.items.count.formatted()) top-level \(inventory.items.count == 1 ? "item" : "items") · \(DiskFormat.bytes(inventory.allocatedBytes)) allocated")
                            .font(.callout.weight(.medium)).monospacedDigit()
                    }
                    if scan.skipped > 0 {
                        Text("\(scan.skipped.formatted()) items skipped. The measured size is partial.")
                            .font(.caption).foregroundStyle(Tints.yellow)
                    }
                    if inventory.items.isEmpty {
                        Text("No items found in Home Trash.").foregroundStyle(Tints.secondaryText)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(inventory.items) { item in
                                    HStack(spacing: 10) {
                                        Image(systemName: item.isDirectory ? "folder" : "doc")
                                            .foregroundStyle(Tints.mint)
                                        Text(item.name).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        Text(DiskFormat.bytes(item.allocatedBytes)).monospacedDigit()
                                            .foregroundStyle(Tints.secondaryText)
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([scan.url(for: item.id)])
                                        }
                                    }
                                    .padding(.vertical, 5)
                                    .accessibilityElement(children: .contain)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(inventory.items.count) * 44, 220))
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("In Trash", systemImage: "trash")
                    .font(.headline).foregroundStyle(Tints.mint)
                Spacer()
                Text(inventory.sizeLabel)
                    .monospacedDigit().foregroundStyle(Tints.secondaryText)
                    .accessibilityLabel("Trash size: " + inventory.sizeLabel)
            }
        }
        .onAppear { inventory.refresh(excludedFolders: m.excludedFolders) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { inventory.refresh(excludedFolders: m.excludedFolders) }
        }
        .onChange(of: m.excludedFolders) { _, _ in inventory.refresh(excludedFolders: m.excludedFolders) }
        .onChange(of: m.busy) { _, busy in
            if !busy && !m.lastTrashedURLs.isEmpty { inventory.refresh(excludedFolders: m.excludedFolders) }
        }
        .onChange(of: inventory.error) { _, error in
            if error != nil { expanded = true }
        }
        .onDisappear { inventory.cancel() }
        .padding(14)
        .background(Tints.mint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(0.22)))
    }
}
