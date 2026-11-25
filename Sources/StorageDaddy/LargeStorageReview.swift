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
    var vm: LumeVMReview?
    var id: String { url.path }

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
    let startWithCodex: Bool
    let onScan: (URL) -> Void
    let onChange: () -> Void
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
            let home = FileManager.default.homeDirectoryForCurrentUser
            let exclusions = model.excludedFolders
            let vmTask = Task.detached(priority: .userInitiated) { try LumeVMReview.discover(home: home, exclusions: exclusions) }
            let known = Task.detached(priority: .utility) { try await LargeStorageEntry.discover(home: home, exclusions: exclusions) }
            await withTaskCancellationHandler {
                do {
                    let machines = try await vmTask.value
                    if !Task.isCancelled {
                        merge(machines.map { vm in
                            LargeStorageEntry(url: vm.url, title: vm.name + " · stopped virtual machine",
                                explanation: "A separate computer stored on this Mac. Deleting it permanently removes its guest files and installed tools.", bytes: vm.bytes, vm: vm)
                        })
                    }
                } catch { if !Task.isCancelled { discoveryError = error.localizedDescription } }
                if let values = try? await known.value, !Task.isCancelled { merge(values) }
            } onCancel: { vmTask.cancel(); known.cancel() }
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
        let home = FileManager.default.homeDirectoryForCurrentUser
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
                let gain = try await Task.detached(priority: .userInitiated) {
                    let before = StartupCapacity(report: SystemInventory.collect())
                    try vm.remove(exclusions: exclusions)
                    let after = StartupCapacity(report: SystemInventory.collect())
                    return before.flatMap { b in after.flatMap { a in b.total == a.total ? a.available - b.available : nil } }
                }.value
                entries.removeAll { $0.id == entry.id }
                notice = "Deleted " + vm.name + "." + (gain.map { " Free space " + ($0 >= 0 ? "increased" : "decreased") + " by " + DiskFormat.bytes(abs($0)) + "." } ?? "")
                onChange()
            } catch { notice = error.localizedDescription }
        }
    }
}
