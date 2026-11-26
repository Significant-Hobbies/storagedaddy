import AppKit
import Darwin
import DiskCore
import SaaSMakerUI
import SwiftUI

struct LargeStorageEntry: Identifiable, Sendable {
    let url: URL
    let title: String
    let explanation: String
    let bytes: Int64
    struct ReviewedFile: Sendable {
        let root: URL
        let node: DiskNode
    }

    var ordinaryFile: ReviewedFile?
    var vm: LumeVMReview?
    var id: String { url.path }

    struct Inventory: Sendable {
        var entries: [LargeStorageEntry] = []
        var errors: [String] = []
        var skippedProtectedRoots: [String] = []
    }

    static func inventory(home: URL, projectFolders: [String], exclusions: [String],
                          onUpdate: @MainActor @Sendable (Inventory) -> Void = { _ in }) async -> Inventory {
        await withTaskGroup(of: Inventory.self) { group in
            group.addTask {
                let avoid = AutomaticScanPrivacy.promptAvoidancePaths(homeDirectory: home, accessStatus: FullDiskAccessProbe.status(homeDirectory: home))
                let common = ["Downloads", "Movies", "Documents", "Desktop", "Projects", "Developer", "Code", "src", "repos"]
                let roots = common.map { home.appendingPathComponent($0) } + projectFolders.map { URL(fileURLWithPath: $0) }
                var inventory = ordinaryFiles(in: roots, exclusions: exclusions + avoid, volume: home)
                let rootPaths = roots.map { $0.standardizedFileURL.path }
                inventory.skippedProtectedRoots = avoid.filter { path in
                    rootPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
                }.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
                return inventory
            }
            group.addTask {
                do { return Inventory(entries: try await discover(home: home, exclusions: exclusions)) }
                catch { return Inventory(errors: ["Large files: " + error.localizedDescription]) }
            }
            group.addTask {
                do {
                    let machines = try LumeVMReview.discover(home: home, exclusions: exclusions)
                    return Inventory(entries: machines.map { vm in
                        Self(url: vm.url, title: vm.name + " · stopped virtual machine",
                             explanation: "Deleting this virtual machine permanently removes its guest files and installed tools.",
                             bytes: vm.bytes, vm: vm)
                    })
                } catch { return Inventory(errors: ["Virtual machines: " + error.localizedDescription]) }
            }
            var result = Inventory()
            for await part in group {
                result.entries += part.entries
                result.errors += part.errors
                result.skippedProtectedRoots += part.skippedProtectedRoots
                let catalog = result.entries.filter { $0.ordinaryFile == nil }
                let covered = FolderExclusions(paths: catalog.map(\.id), resolveAliases: false)
                result.entries.removeAll { $0.ordinaryFile != nil && covered.blocksCleanup($0.url) }
                result.entries.sort {
                    if $0.bytes == $1.bytes { return $0.id < $1.id }
                    return $0.bytes > $1.bytes
                }
                if !Task.isCancelled { await onUpdate(result) }
            }
            return result
        }
    }

    static func ordinaryFiles(in roots: [URL], exclusions: [String], volume: URL,
                              minimumBytes: Int64 = 100_000_000, limitPerRoot: Int = 12_000) -> Inventory {
        var disk = stat()
        guard lstat(volume.path, &disk) == 0 else { return Inventory() }
        let policy = FolderExclusions(paths: exclusions + [volume.appendingPathComponent("Library").path])
        let stopFolders: Set<String> = ["node_modules", "DerivedData", "Pods"]
        let fm = FileManager.default
        var walked = Set<String>()
        var found: [String: Self] = [:]
        var capped = false
        for root in roots {
            let path = root.standardizedFileURL.path
            guard !Task.isCancelled, path.hasPrefix(volume.standardizedFileURL.path + "/"),
                  !path.dropFirst(volume.standardizedFileURL.path.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  !policy.contains(path), !isSensitivePath(root), walked.insert(path).inserted,
                  path == root.resolvingSymlinksInPath().path else { continue }
            var rootInfo = stat()
            guard lstat(path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
                  rootInfo.st_dev == disk.st_dev,
                  let walker = fm.enumerator(at: root, includingPropertiesForKeys: [],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for (index, element) in walker.enumerated() {
                if Task.isCancelled { return Inventory() }
                if index >= limitPerRoot { capped = true; break }
                guard let url = element as? URL else { continue }
                var info = stat()
                guard !isSensitiveComponent(url.lastPathComponent), !policy.contains(url.standardizedFileURL.path), lstat(url.path, &info) == 0, info.st_dev == disk.st_dev else {
                    walker.skipDescendants(); continue
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    if stopFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { continue }
                let bytes = Int64(info.st_blocks) * 512
                guard bytes >= minimumBytes else { continue }
                let stamp = info.st_mtimespec
                let modified = Date(timeIntervalSince1970: Double(stamp.tv_sec) + Double(stamp.tv_nsec) / 1_000_000_000)
                let node = DiskNode(id: 1, parent: 0, name: url.lastPathComponent, isDirectory: false,
                                    logicalBytes: Int64(info.st_size), allocatedBytes: bytes, modified: modified,
                                    device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
                found[url.path] = Self(url: url, title: url.lastPathComponent,
                    explanation: "Personal or project file. You can restore it from Trash until you empty it.", bytes: bytes,
                    ordinaryFile: ReviewedFile(root: root, node: node))
                if found.count > 20, let smallest = found.values.min(by: { $0.bytes < $1.bytes }) { found.removeValue(forKey: smallest.id) }
            }
        }
        return Inventory(entries: found.values.sorted { $0.bytes > $1.bytes },
                         errors: capped ? ["The large-file search stopped after \(limitPerRoot.formatted()) entries in a folder. Scan that folder for full coverage."] : [])
    }

    static func discover(home: URL, exclusions: [String]) async throws -> [Self] {
        let catalog = [
            ("Library/Application Support/com.codevetter.desktop/codevetter.db", "CodeVetter database", "Contains analysis snapshots and review history. Removing the database would erase both."),
            ("Library/Application Support/Cursor/snapshots", "Cursor snapshots", "Stores previous versions of work. Removing snapshots can cost you the ability to restore an edit."),
            ("Library/Application Support/Pace/LocalAppBackups.noindex", "Pace rollback copies", "Older app builds kept for rollback. Inspect individual versions before removing any."),
            ("Library/Application Support/Fleet/Storage Cleanup Recovery", "Cleanup recovery backups", "Verified copies made before past cleanup. Removing one gives up that recovery point."),
            ("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", "Chrome offline AI model", "Downloaded model weights for on-device AI. Chrome may need to download them again."),
            (".cache/uv", "Python package cache", "uv can share these files with installed environments. An active uv process can prevent cleanup.")
        ]
        let policy = FolderExclusions(paths: exclusions)
        var entries: [Self] = []
        for (relative, title, detail) in catalog {
            try Task.checkCancellation()
            let url = home.appendingPathComponent(relative).standardizedFileURL
            var st = stat()
            guard url.path == url.resolvingSymlinksInPath().path, !policy.blocksCleanup(url),
                  lstat(url.path, &st) == 0, st.st_uid == getuid() else { continue }
            let bytes: Int64
            if st.st_mode & S_IFMT == S_IFREG { bytes = Int64(st.st_blocks) * 512 }
            else if st.st_mode & S_IFMT == S_IFDIR {
                guard let size = try? PackageToolCommand.run(executable: URL(fileURLWithPath: "/usr/bin/du"),
                    arguments: ["-skx", url.path], directory: home, timeout: 30), size.status == 0,
                      let first = size.output.split(whereSeparator: { $0.isWhitespace }).first,
                      let kib = Int64(first), kib > 0, kib <= Int64.max / 1024 else { continue }
                bytes = kib * 1024
            } else { continue }
            if bytes >= 100_000_000 { entries.append(Self(url: url, title: title, explanation: detail, bytes: bytes)) }
        }
        return entries.sorted { $0.bytes > $1.bytes }
    }
}

struct LargeStorageReviewSheet: View {
    @EnvironmentObject private var model: ExplorerModel
    @Environment(\.dismiss) private var dismiss
    let home: URL
    let measured: LargeStorageEntry.Inventory?
    let startWithCodex: Bool
    let onScan: (URL) -> Void
    let onChange: (StartupCapacity?) -> Void
    @State private var entries: [LargeStorageEntry] = []
    @State private var pending: LargeStorageEntry?
    @State private var loading = true
    @State private var asking = false
    @State private var removing = false
    @State private var notice: String?
    @State private var discoveryError: String?
    @State private var codexTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Large items").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.disabled(removing)
            }
            Text("Sizes show disk allocation. Shared files can reduce how much space you get back.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if let notice { Text(notice).textSelection(.enabled) }
            if let discoveryError { Text(discoveryError).foregroundStyle(Tints.yellow) }
            if loading { ProgressView("Measuring large items…") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.title).font(.headline)
                                Spacer()
                                Text(DiskFormat.bytes(entry.bytes)).monospacedDigit()
                            }
                            Text(entry.explanation).font(.callout).foregroundStyle(Tints.secondaryText)
                            Text(StorageLabels.location(entry.url.path)).font(.caption).lineLimit(1).truncationMode(.middle).help(entry.url.path)
                            HStack {
                                if entry.vm != nil {
                                    Button("Delete VM…", role: .destructive) { pending = entry }
                                } else if entry.url.hasDirectoryPath || (try? entry.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                    Button("Inspect files") { onScan(entry.url); dismiss() }
                                }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            }
                        }
                        Divider()
                    }
                }
            }.disabled(removing)
            if !loading && entries.isEmpty { Text("No large items found in the checked locations.") }
            HStack {
                Button("Look for more with Codex") { askCodex() }.disabled(asking || removing)
                if asking { ProgressView().controlSize(.small) }
            }
            Text("Uses your signed-in Codex CLI to suggest cache locations. File names, contents and scan results stay on this Mac.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .padding(24).frame(minWidth: 500, idealWidth: 620, minHeight: 360, idealHeight: 530)
        .background(AppColors.canvas)
        .interactiveDismissDisabled(removing)
        .task {
            if startWithCodex { askCodex() }
            let inventory: LargeStorageEntry.Inventory
            if let measured { inventory = measured }
            else { inventory = await LargeStorageEntry.inventory(home: home, projectFolders: model.developerCleanupFolders, exclusions: model.excludedFolders) }
            guard !Task.isCancelled else { return }
            merge(inventory.entries)
            if !inventory.errors.isEmpty { discoveryError = inventory.errors.joined(separator: "\n") }
            loading = false
        }
        .onDisappear { codexTask?.cancel() }
        .alert("Delete stopped virtual machine?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Delete " + (entry.vm?.name ?? "VM"), role: .destructive) { remove(entry) }
        } message: { entry in
            Text("This permanently deletes " + (entry.vm?.name ?? entry.title) + ", including its guest files and installed tools.")
        }
    }

    private func merge(_ additions: [LargeStorageEntry]) {
        var seen = Set(entries.map(\.id))
        entries.append(contentsOf: additions.filter { seen.insert($0.id).inserted })
        entries.sort { $0.bytes > $1.bytes }
    }

    private func askCodex() {
        guard !asking else { return }
        asking = true
        notice = nil
        let exclusions = model.excludedFolders
        codexTask = Task {
            defer { asking = false }
            do {
                let suggestions = try await CodexStorageDiscovery.discover(home: home, exclusions: exclusions)
                try Task.checkCancellation()
                let prior = entries.count
                merge(suggestions.map { LargeStorageEntry(url: $0.url, title: $0.title, explanation: $0.explanation, bytes: $0.bytes) })
                notice = entries.count == prior ? "Codex found no additional measured cache locations." : "Added \(entries.count - prior) measured cache locations from Codex."
            } catch is CancellationError {} catch { notice = error.localizedDescription }
        }
    }

    private func remove(_ entry: LargeStorageEntry) {
        guard let vm = entry.vm, !removing else { return }
        removing = true
        let exclusions = model.excludedFolders
        Task {
            defer { removing = false }
            do {
                let (before, after) = try await Task.detached(priority: .userInitiated) {
                    let before = StartupCapacity(report: SystemInventory.collect())
                    try vm.remove(exclusions: exclusions)
                    let after = StartupCapacity(report: SystemInventory.collect())
                    return (before, after)
                }.value
                let gain = before.flatMap { b in after.flatMap { a in b.total == a.total ? a.available - b.available : nil } }
                entries.removeAll { $0.id == entry.id }
                notice = "Deleted " + vm.name + "." + (gain.map { " Free space " + ($0 >= 0 ? "increased" : "decreased") + " by " + DiskFormat.bytes(abs($0)) + "." } ?? "")
                onChange(after)
            } catch { notice = error.localizedDescription }
        }
    }
}
