import AppKit
import SwiftUI
import DiskCore

protocol FilenameSearchService: Sendable {
    func search(scan: ScanResult, identity: UUID, query: String, scope: Int) async throws -> FilenameSearchReply
}
extension FinderSearchEngine: FilenameSearchService {}

struct FilenameSearchContext: Equatable {
    let identity: UUID
    let query: String
    let scope: Int
}

@MainActor final class FilenameSearchModel: ObservableObject {
    @Published private(set) var resultContext: FilenameSearchContext?
    @Published private(set) var hits: [FilenameSearchHit] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var truncated = false
    private let engine: any FilenameSearchService
    private var generation = UUID()
    init(engine: any FilenameSearchService = FinderSearchEngine()) { self.engine = engine }

    func update(scan: ScanResult?, identity: UUID, query: String, scope: Int) async {
        let token = UUID(); generation = token
        resultContext = nil; hits = []; error = nil; truncated = false; busy = false
        guard let scan, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        do {
            try await Task.sleep(for: .milliseconds(150))
            let reply = try await engine.search(scan: scan, identity: identity, query: query, scope: scope)
            try Task.checkCancellation()
            guard generation == token else { return }
            guard reply.ok else {
                error = reply.error ?? "Filename search failed."; busy = false; return
            }
            let valid = (reply.hits ?? []).filter { scan.nodes.indices.contains($0.id) }
            resultContext = FilenameSearchContext(identity: identity, query: query, scope: scope)
            hits = Array(valid.prefix(200)); truncated = valid.count > 200
            busy = false
        } catch {
            guard generation == token else { return }
            busy = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

struct FilenameSearchView: View {
    @EnvironmentObject var m: ExplorerModel
    @StateObject private var searchModel: FilenameSearchModel
    @State private var query = ""
    @State private var currentFolderOnly = false
    @State private var retry = UUID()
    @FocusState private var searchFocused: Bool
    init(model: FilenameSearchModel = FilenameSearchModel(), query: String = "") {
        _searchModel = StateObject(wrappedValue: model)
        _query = State(initialValue: query)
    }
    private struct SearchKey: Equatable {
        let identity: UUID
        let query: String
        let scope: Int
        let retry: UUID
    }
    private var key: SearchKey {
        let folderIsValid = m.scan.map { $0.nodes.indices.contains(m.focus) && $0.nodes[m.focus].isDirectory } ?? false
        return SearchKey(identity: m.filenameSearchIdentity, query: query, scope: currentFolderOnly && folderIsValid ? m.focus : 0, retry: retry)
    }
    private var resultsAreCurrent: Bool {
        searchModel.resultContext == FilenameSearchContext(identity: key.identity, query: key.query, scope: key.scope)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Files").font(.largeTitle.weight(.semibold))
            Text("Fuzzy filename search across your scan, powered by FinderSearch. Results use scan metadata; rescan to include changes.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tints.mint)
                TextField("Filename or filters, e.g. report ext:pdf", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search scanned filenames").accessibilityIdentifier("filename-search")
                if !query.isEmpty { Button("Clear") { query = "" } }
            }.padding(12).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tints.mint.opacity(0.28)))
            ViewThatFits(in: .horizontal) {
                HStack { scopeToggle; Spacer(); filterHint }
                VStack(alignment: .leading, spacing: 8) { scopeToggle; filterHint }
            }
            if let scan = m.scan {
                Text("Searching \(StorageLabels.location(scan.url(for: key.scope).path)) and its subfolders")
                    .font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(2)
                if scan.skipped > 0 {
                    Text("Skipped and excluded locations are not searched.").font(.caption).foregroundStyle(Tints.yellow)
                }
            }
            if searchModel.busy || (!resultsAreCurrent && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchModel.error == nil) {
                HStack { ProgressView().controlSize(.small); Text("Searching scan…").foregroundStyle(Tints.secondaryText) }
                Spacer()
            } else if let error = searchModel.error {
                StorageEmptyView("Search needs attention", systemImage: "exclamationmark.magnifyingglass", description: Text(error))
                Button("Try again") { retry = UUID() }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                StorageEmptyView("Find a file in your scan", systemImage: "magnifyingglass", description: Text("Search filenames with typo tolerance, or narrow results by extension, size, kind and modification date."))
            } else if searchModel.hits.isEmpty {
                StorageEmptyView("No matching files", systemImage: "magnifyingglass", description: Text("Try a shorter filename, fewer filters, or search the whole scan."))
            } else if let scan = m.scan {
                Text(searchModel.truncated ? "Showing the first 200 matches · narrow your search for more" : "\(searchModel.hits.count) \(searchModel.hits.count == 1 ? "match" : "matches") · sorted by relevance")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchModel.hits) { hit in
                            if scan.nodes.indices.contains(hit.id) { resultRow(scan.nodes[hit.id], scan: scan) }
                        }
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black).buttonStyle(StorageButtonStyle())
            .task(id: key) {
                let request = key
                await searchModel.update(scan: m.scan, identity: request.identity, query: request.query, scope: request.scope)
            }
            .onAppear { searchFocused = true }
    }
    private var scopeToggle: some View {
        Toggle("Current folder only", isOn: $currentFolderOnly).toggleStyle(.checkbox).font(.callout)
            .help("Search the folder currently open in Storage and its descendants.")
    }
    private var filterHint: some View {
        Text("ext:pdf  size:>100mb  mtime:<7d  kind:dir")
            .font(.caption.monospaced()).foregroundStyle(Tints.secondaryText)
            .textSelection(.enabled)
            .help("Size filters use logical bytes from the scan. mtime:<7d finds files modified in the last seven days.")
    }
    private func resultRow(_ node: DiskNode, scan: ScanResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: node.isSymlink ? "link" : node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(Tints.forNode(node)).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name).fontWeight(.medium).lineLimit(1)
                Text(StorageLabels.location(scan.url(for: node.id).path)).font(.caption)
                    .foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                    .help(scan.url(for: node.id).path)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(StorageLabels.size(node, allocated: m.allocated)).font(.caption).monospacedDigit()
            Menu {
                Button("Inspect in Storage") {
                    m.inspectSearchResult(node.id)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([scan.url(for: node.id)]) }
                Button(m.staged.contains(node.id) ? "Staged for Cleanup" : "Add to Cleanup") { m.stage(node.id) }
                    .disabled(m.staged.contains(node.id) || m.busy || node.parent == nil)
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(node.name)")
        }.padding(.vertical, 12)
    }
}
