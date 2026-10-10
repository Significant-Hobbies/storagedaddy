import AppKit
import DiskCore
import SwiftUI
import SaaSMakerUI

enum AISessionsSection: String, CaseIterable {
    case sessions = "Sessions"
    case archive = "Archive"
}

private enum AISessionSort: String, CaseIterable {
    case recent = "Recent"
    case size = "Size"
    case oldest = "Oldest"
}

@MainActor
final class AISessionsModel: ObservableObject {
    @Published var report: AISessionInventoryReport?
    @Published var loading = false
    @Published var errorMessage: String?
    private var loadGeneration = 0
    private let discover: @Sendable () throws -> AISessionInventoryReport

    init(discover: @escaping @Sendable () throws -> AISessionInventoryReport = { try AISessionInventory.discover() }) {
        self.discover = discover
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                loading = false
            }
        }
        let discover = self.discover
        let worker = Task.detached(priority: .utility) {
            try discover()
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            report = result
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            errorMessage = "storagedaddy couldn’t finish inventorying local AI history. Try Refresh after checking folder access."
        }
    }
}

struct AISessionsView: View {
    @EnvironmentObject private var m: ExplorerModel
    @StateObject private var model = AISessionsModel()
    @State private var filter = ""
    @State private var provider: AISessionProvider?
    @State private var sort: AISessionSort = .recent
    @State private var showCoverage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(spacing: 10) {
                ForEach(AISessionsSection.allCases, id: \.self) { section in
                    Button(section.rawValue.lowercased()) { m.aiSessionsSection = section }.accessibilityLabel(section.rawValue)
                        .buttonStyle(StorageButtonStyle(prominent: m.aiSessionsSection == section))
                }
                Spacer()
            }
            if m.aiSessionsSection == .archive {
                ConversationArchiveView(model: m.conversationArchive, inventory: model.report)
            } else {
                sessions
            }
        }
        .padding(24)
        .background(Color.black)
        .buttonStyle(StorageButtonStyle())
        .task(id: m.aiSessionsRefreshID) { await model.load() }
        .sheet(isPresented: $showCoverage) { coverageSheet }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("local ai history").accessibilityLabel("LOCAL AI HISTORY")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Tints.mint)
                SMSectionHeader("AI Sessions", size: 28).accessibilityLabel("AI Sessions")
                Text("See how much space Claude and Codex history files use, without running a disk scan.")
                    .foregroundStyle(Tints.secondaryText)
            }
            DoodleArt(topic: .agents).frame(width: 94, height: 94)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button("refresh", systemImage: "arrow.clockwise") { m.requestAISessionsRefresh() }.accessibilityLabel("Refresh")
                .disabled(model.loading)
        }
    }

    @ViewBuilder private var sessions: some View {
        if model.loading, model.report == nil {
            StorageEmptyView("Finding local AI history…", systemImage: "bubble.left.and.text.bubble.right", description: Text("Checking the standard Claude and Codex folders directly."))
        } else if let error = model.errorMessage, model.report == nil {
            VStack(spacing: 14) {
                StorageEmptyView("Session inventory needs attention", systemImage: "exclamationmark.bubble", description: Text(error))
                Button("try again", systemImage: "arrow.clockwise") { m.requestAISessionsRefresh() }.accessibilityLabel("Try Again")
                    .buttonStyle(StorageButtonStyle(prominent: true))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.report {
            let matchingRows = rows(in: report.sessions)
            VStack(alignment: .leading, spacing: 14) {
                summary(report)
                if let error = model.errorMessage {
                    refreshFailureNotice(error)
                }
                if report.coverage.isPartial {
                    partialCoverageNotice(report.coverage)
                }
                controls(matchingRows: matchingRows)
                if matchingRows.isEmpty {
                    StorageEmptyView(
                        report.sessions.isEmpty ? "No local AI history files found" : "No matching history files",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(report.sessions.isEmpty
                            ? "Claude and Codex history files will appear here automatically when their standard folders exist."
                            : "Try another project, provider, session ID or filename.")
                    )
                    if !report.sessions.isEmpty, hasFilters {
                        Button("clear filters", systemImage: "xmark.circle") { clearFilters() }.accessibilityLabel("Clear filters")
                            .buttonStyle(StorageButtonStyle(prominent: true))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matchingRows) { sessionRow($0) }
                        }
                    }
                }
                footer(report)
            }
        }
    }

    private func summary(_ report: AISessionInventoryReport) -> some View {
        let claude = report.sessions.filter { $0.provider == .claude }
        let codex = report.sessions.filter { $0.provider == .codex }
        return HStack(spacing: 12) {
            metricCard("ON DISK", DiskFormat.bytes(report.sessions.reduce(0) { $0 + $1.allocatedBytes }), "across \(report.sessions.count.formatted()) transcript files", Tints.mint)
            metricCard("CLAUDE", DiskFormat.bytes(claude.reduce(0) { $0 + $1.allocatedBytes }), "\(claude.count.formatted()) transcript files", Tints.coral, provider: .claude)
            metricCard("CODEX", DiskFormat.bytes(codex.reduce(0) { $0 + $1.allocatedBytes }), "\(codex.count.formatted()) transcript files", Tints.electricBlue, provider: .codex)
            metricCard("CODEX ARCHIVE", "\(report.sessions.filter(\.isArchived).count.formatted())", "transcript files archived by Codex", Tints.yellow)
        }
    }

    private func metricCard(_ label: String, _ value: String, _ detail: String, _ color: Color, provider: AISessionProvider? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.3).foregroundStyle(color)
                Spacer()
                if let provider { AIProviderIcon(provider: provider, size: 24) }
            }
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .storagePanel()
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.24)))
    }

    private func controls(matchingRows: [AISessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField("Search project or session ID", text: $filter)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .frame(minWidth: 180, maxWidth: 300)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tints.mint.opacity(0.38)))
                    .accessibilityLabel("Search AI sessions by project, provider, session ID or filename")
                Text("Provider").font(.caption).foregroundStyle(Tints.secondaryText)
                Button("all") { provider = nil }.accessibilityLabel("All").buttonStyle(StorageButtonStyle(prominent: provider == nil))
                ForEach(AISessionProvider.allCases, id: \.self) { item in
                    Button { provider = item } label: {
                        HStack(spacing: 6) {
                            AIProviderIcon(provider: item, size: 16)
                            Text(item.rawValue)
                        }
                    }
                        .buttonStyle(StorageButtonStyle(prominent: provider == item))
                }
                if hasFilters {
                    Button("clear filters", systemImage: "xmark.circle") { clearFilters() }.accessibilityLabel("Clear filters")
                        .buttonStyle(StorageButtonStyle())
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Text("Sort by").font(.caption).foregroundStyle(Tints.secondaryText)
                ForEach(AISessionSort.allCases, id: \.self) { item in
                    Button(item.rawValue.lowercased()) { sort = item }.accessibilityLabel(item.rawValue)
                        .buttonStyle(StorageButtonStyle(prominent: sort == item))
                }
                Spacer()
                Text("Showing \(matchingRows.count.formatted()) · \(DiskFormat.bytes(matchingRows.reduce(0) { $0 + $1.allocatedBytes }))")
                    .foregroundStyle(Tints.secondaryText)
                Button("archive older…", systemImage: "archivebox") { m.openConversationArchive() }.accessibilityLabel("Archive Older…")
                    .buttonStyle(StorageButtonStyle(prominent: true))
            }
        }
    }

    private func rows(in sessions: [AISessionRecord]) -> [AISessionRecord] {
        let filtered = sessions.filter { session in
            (provider == nil || session.provider == provider) && session.matches(search: filter)
        }
        return filtered.sorted {
            switch sort {
            case .recent:
                return $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified
            case .oldest:
                return $0.modified == $1.modified ? $0.path < $1.path : $0.modified < $1.modified
            case .size:
                return $0.allocatedBytes == $1.allocatedBytes ? $0.modified > $1.modified : $0.allocatedBytes > $1.allocatedBytes
            }
        }
    }

    private var hasFilters: Bool { !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || provider != nil }

    private func clearFilters() {
        filter = ""
        provider = nil
    }

    private func refreshFailureNotice(_ message: String) -> some View {
        Label {
            Text("Refresh failed. Showing the previous inventory. \(message)")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(Tints.yellow)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tints.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tints.yellow.opacity(0.24)))
    }

    private func partialCoverageNotice(_ coverage: AISessionInventoryCoverage) -> some View {
        HStack(spacing: 8) {
            Label {
                Text("Results may be incomplete · \(coverageSummary(coverage))")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            Spacer()
            Button("view coverage") { showCoverage = true }.accessibilityLabel("View coverage")
                .font(.caption.weight(.semibold))
        }
        .font(.caption)
        .foregroundStyle(Tints.yellow)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tints.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tints.yellow.opacity(0.24)))
        .help(coverageSummary(coverage))
    }

    private func coverageSummary(_ coverage: AISessionInventoryCoverage) -> String {
        var details: [String] = []
        if coverage.unreadableCount > 0 { details.append("\(coverage.unreadableCount) unreadable entries") }
        if coverage.skippedLinks > 0 { details.append("\(coverage.skippedLinks) links skipped") }
        if coverage.entryLimitReached { details.append("directory-entry limit reached") }
        if coverage.sessionLimitReached { details.append("transcript-file limit reached") }
        return details.joined(separator: " · ")
    }

    private func sessionRow(_ session: AISessionRecord) -> some View {
        HStack(spacing: 14) {
            AIProviderIcon(provider: session.provider, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(projectName(session)).font(.headline).lineLimit(1)
                Text(projectLocation(session)).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                    .help(session.project ?? session.path)
                Text("Session \(session.shortHistoryIdentifier)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tints.secondaryText).lineLimit(1)
                    .help(session.historyIdentifier)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(session.provider.rawValue)
                if session.isArchived { Text("archived by codex").accessibilityLabel("ARCHIVED BY CODEX").foregroundStyle(Tints.yellow) }
            }.font(.caption.weight(.semibold)).frame(width: 125, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(session.modified, style: .relative)
                Text("since last change").font(.caption).foregroundStyle(Tints.secondaryText)
            }.frame(width: 125, alignment: .trailing).help(session.modified.formatted())
            VStack(alignment: .trailing, spacing: 4) {
                Text(DiskFormat.bytes(session.allocatedBytes)).monospacedDigit()
                Text("\(DiskFormat.bytes(session.logicalBytes)) logical").font(.caption).foregroundStyle(Tints.secondaryText)
            }.frame(width: 135, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .help("Reveal session in Finder")
            .accessibilityLabel("Reveal \(projectName(session)) session in Finder")
        }
        .contextMenu {
            Button("copy session identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.historyIdentifier, forType: .string)
            }.accessibilityLabel("Copy session identifier")
            Button("reveal in finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
            }.accessibilityLabel("Reveal in Finder")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
        .background((session.provider == .claude ? Tints.coral : Tints.electricBlue).opacity(0.025))
        .overlay(alignment: .bottom) { Divider().overlay(Tints.mint.opacity(0.15)) }
    }

    private func projectName(_ session: AISessionRecord) -> String {
        guard let project = session.project else { return "Unknown project" }
        let name = URL(fileURLWithPath: project).lastPathComponent
        return name.isEmpty ? StorageLabels.location(project) : name
    }

    private func projectLocation(_ session: AISessionRecord) -> String {
        if let project = session.project { return StorageLabels.location(project) }
        return session.isArchived ? "Archived by Codex" : "Project metadata unavailable"
    }

    private func footer(_ report: AISessionInventoryReport) -> some View {
        HStack {
            Label("Local and read-only · no disk scan · no uploads", systemImage: "lock.shield")
                .foregroundStyle(Tints.mint)
            Spacer()
            Text("\(report.coverage.visitedEntries.formatted()) entries checked · \(String(format: "%.2f", report.elapsed)) s")
                .foregroundStyle(Tints.secondaryText)
            Button("coverage", systemImage: "info.circle") { showCoverage = true }.accessibilityLabel("Coverage")
        }.font(.caption)
    }

    private var coverageSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SMSectionHeader("AI history coverage", size: 22).accessibilityLabel("AI history coverage")
                Spacer()
                Button("done") { showCoverage = false }.accessibilityLabel("Done")
            }
            Text("storagedaddy inventories regular JSONL transcript files in the standard local Claude and Codex folders. Claude totals include nested subagent transcripts. It does not display conversation text, upload data, alter files, or require a storage scan.")
                .foregroundStyle(Tints.secondaryText)
            if let coverage = model.report?.coverage {
                Text("\(coverage.visitedEntries.formatted()) entries checked · \(coverage.unreadableCount.formatted()) traversal/stat failures · \(coverage.skippedLinks.formatted()) links skipped")
                ForEach(coverage.existingRoots, id: \.self) { path in
                    Label("Checked · \(StorageLabels.location(path))", systemImage: "checkmark.circle")
                }
                ForEach(coverage.missingRoots, id: \.self) { path in
                    Label("Not present · \(StorageLabels.location(path))", systemImage: "minus.circle")
                        .foregroundStyle(Tints.secondaryText)
                }
                if coverage.entryLimitReached { Label("The directory-entry limit was reached. Results are partial.", systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow) }
                if coverage.sessionLimitReached { Label("The transcript-file result limit was reached. Results are partial.", systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow) }
                if coverage.unreadableCount > 0 { Text("Some filesystem entries could not be inspected, so results are partial.").foregroundStyle(Tints.yellow) }
                if coverage.skippedLinks > 0 { Text("Symlink entries were skipped, so results are partial.").foregroundStyle(Tints.yellow) }
            }
            Text("Counts describe transcript files, not guaranteed distinct conversations. Custom CLAUDE_CONFIG_DIR and CODEX_HOME locations are not included. Project names come from a bounded metadata read of at most 64 KiB per file; Unknown project can mean access failed or metadata was missing, malformed, or beyond that limit. On-disk size is storage allocated by macOS; logical size is the file’s content length.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            Spacer()
        }
        .padding(24)
        .frame(width: 680, height: 470)
        .background(Color.black)
        .buttonStyle(StorageButtonStyle())
    }
}
