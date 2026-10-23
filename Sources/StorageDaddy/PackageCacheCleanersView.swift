import AppKit
import DiskCore
import SwiftUI

private struct CacheToolLocation: Identifiable, Sendable {
    let tool: PackageCacheTool
    let executable: URL?
    let cache: URL?
    let note: String
    var id: PackageCacheTool { tool }
}

struct PackageCacheCleanersView: View {
    @EnvironmentObject private var m: ExplorerModel
    @State private var locations: [CacheToolLocation] = []
    @State private var loading = false
    @State private var review: CacheToolLocation?
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Package-manager cleanup").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh tools") { Task { await refresh() } }.disabled(loading || m.busy)
            }
            Text("Run the tool’s own cleaner, including custom cache locations. Sizes come from a scan, not estimates from another Mac. Homebrew also removes old installed versions.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if loading { ProgressView("Locating caches…").controlSize(.small) }
            ForEach(locations) { location in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(location.tool.command).font(.system(.callout, design: .monospaced))
                        Spacer()
                        if let cache = location.cache {
                            Button("Measure") { m.start(cache, destination: .developer) }.disabled(m.busy)
                        }
                        Button("Review…") { confirmed = false; review = location }
                            .disabled(location.executable == nil || location.cache == nil || m.busy || m.snapshotBusy || m.macTools?.isBusy == true)
                    }
                    Text(location.cache.map { StorageLabels.location($0.path) } ?? location.note)
                        .font(.caption).foregroundStyle(Tints.secondaryText).textSelection(.enabled)
                }.padding(.vertical, 6)
            }
            if let notice = m.cacheCommandNotice {
                Text(notice).font(.callout).foregroundStyle(Tints.yellow).textSelection(.enabled)
            }
        }.padding(18).storagePanel()
            .task { if locations.isEmpty { await refresh() } }
            .sheet(item: $review) { location in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Run \(location.tool.command)?").font(.title2.weight(.semibold))
                    Text(location.tool.consequence).fixedSize(horizontal: false, vertical: true)
                    if let cache = location.cache { Text(cache.path).font(.callout.monospaced()).textSelection(.enabled) }
                    Text("Close package installs and builds first. The tool runs in your Home folder. This bypasses Trash; StorageDaddy cannot undo it.")
                        .foregroundStyle(Tints.secondaryText)
                    Toggle("I reviewed this cleanup and understand it is permanent", isOn: $confirmed)
                    HStack {
                        Button("Cancel") { review = nil }
                        Spacer()
                        Button("Run cleaner") {
                            if let executable = location.executable, let cache = location.cache {
                                m.cleanPackageCache(location.tool, executable: executable, cache: cache)
                            }
                            review = nil
                        }.disabled(!confirmed || m.busy).buttonStyle(StorageButtonStyle(prominent: true))
                    }
                }.padding(28).frame(width: 540).background(AppColors.canvas).buttonStyle(StorageButtonStyle())
            }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        let excluded = m.excludedFolders
        let worker = Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return PackageCacheTool.allCases.map { tool -> CacheToolLocation in
                guard let executable = tool.executable(home: home) else {
                    return CacheToolLocation(tool: tool, executable: nil, cache: nil, note: "Tool not found in standard locations or PATH")
                }
                do {
                    try Task.checkCancellation()
                    let cache = try tool.cacheDirectory(executable: executable, home: home)
                    guard !FolderExclusions(paths: excluded).blocksCleanup(cache) else {
                        return CacheToolLocation(tool: tool, executable: executable, cache: nil, note: "Cache excluded in Settings")
                    }
                    return CacheToolLocation(tool: tool, executable: executable, cache: cache, note: "")
                } catch {
                    return CacheToolLocation(tool: tool, executable: executable, cache: nil, note: error.localizedDescription)
                }
            }
        }
        locations = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        loading = false
    }
}

extension ExplorerModel {
    func cleanPackageCache(_ tool: PackageCacheTool, executable: URL, cache: URL) {
        guard !busy, !moves.busy, !snapshotBusy, macTools?.isBusy != true, !conversationArchive.busy, staged.isEmpty,
              !FolderExclusions(paths: excludedFolders).blocksCleanup(cache) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let exclusions = FolderExclusions(paths: excludedFolders)
        busy = true
        cacheCommandNotice = "Running \(tool.command)…"
        progress = "Running \(tool.command)…"
        cacheCommandTask = Task {
            defer { busy = false; cacheCommandTask = nil }
            do {
                let worker = Task.detached(priority: .utility) {
                    // Re-resolve the cache immediately before executing the reviewed command.
                    let current = try tool.cacheDirectory(executable: executable, home: home)
                    guard current == cache, !exclusions.blocksCleanup(current) else { throw NSError(domain: "CacheCleaner", code: 3, userInfo: [NSLocalizedDescriptionKey: "The cache location or exclusions changed. Refresh tools and review again."]) }
                    if tool == .brew {
                        let prefix = try PackageToolCommand.run(executable: executable, arguments: ["--prefix"], directory: home, timeout: 20)
                        let path = prefix.output.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard prefix.status == 0, path.hasPrefix("/"), !exclusions.blocksCleanup(URL(fileURLWithPath: path)) else {
                            throw NSError(domain: "CacheCleaner", code: 4, userInfo: [NSLocalizedDescriptionKey: "Homebrew’s installed prefix could not be checked or contains an excluded folder. Its cleaner was not run."])
                        }
                        let environment = ProcessInfo.processInfo.environment
                        let logs = environment["HOMEBREW_LOGS"] ?? home.appendingPathComponent("Library/Logs/Homebrew").path
                        let temporary = environment["HOMEBREW_TEMP"] ?? "/private/tmp"
                        guard [logs, temporary].allSatisfy({ $0.hasPrefix("/") && !exclusions.blocksCleanup(URL(fileURLWithPath: $0)) }) else {
                            throw NSError(domain: "CacheCleaner", code: 5, userInfo: [NSLocalizedDescriptionKey: "Homebrew’s logs or temporary cleanup scope contains an excluded folder. Its cleaner was not run."])
                        }
                    }
                    return try PackageToolCommand.run(executable: executable, arguments: tool.arguments, directory: home)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                cacheCommandNotice = "\(tool.command) \(result.status == 0 ? "finished" : "exited with status \(result.status)"). Measure again to update sizes; partial cleanup is possible.\n" + result.output
                if !cleanupRefreshPaths.contains(cache.path) { cleanupRefreshPaths.append(cache.path) }
            } catch is CancellationError { cacheCommandNotice = "Cleaner stopped. Cleanup may be partial; measure the cache again." }
            catch { cacheCommandNotice = error.localizedDescription }
            progress = "Package cleanup finished · Measure again for current totals"
        }
    }
}
