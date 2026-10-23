import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DiskCore

@MainActor final class ConversationArchiveModel: ObservableObject {
    enum Provider: String, CaseIterable {
        case all = "Both", codex = "Codex", claude = "Claude"
        var sessionProvider: AISessionProvider? {
            switch self {
            case .all: nil
            case .codex: .codex
            case .claude: .claude
            }
        }
    }
    struct Completed {
        let receipt: ConversationArchiveReceipt
        let url: URL
        let bytes: Int64
        let elapsed: TimeInterval
        let cleanup: VerifiedArchiveCleanup?
    }
    @Published var provider: Provider = .all { didSet { if provider != oldValue && !busy { completed = nil; status = "" } } }
    @Published var before = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date() { didSet { if before != oldValue && !busy { completed = nil; status = "" } } }
    @Published var busy = false
    @Published var status = ""
    @Published var completed: Completed?
    @Published var started: Date?
    @Published var reviewCleanup = false
    @Published var cleanupAcknowledged = false
    @Published var trashedURLs: [URL] = []
    @Published var cleanupFinished = false
    private var process: Process?
    private var cancellationRequested = false
    private let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/memory-pack")
    private let didMoveOriginals: () -> Void
    init(didMoveOriginals: @escaping () -> Void = {}) {
        self.didMoveOriginals = didMoveOriginals
    }
    var available: Bool { FileManager.default.isExecutableFile(atPath: helper.path) }
    var cancellable: Bool { process?.isRunning == true }

    func chooseDestination() {
        guard !busy, available else { return }
        let panel = NSSavePanel()
        panel.title = "Export older conversations"
        panel.prompt = "Export Archive"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let date = Calendar.current.startOfDay(for: before)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Conversations-before-\(formatter.string(from: date)).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(to: destination, before: date)
    }

    private func export(to destination: URL, before cutoff: Date) {
        let scoped = destination.startAccessingSecurityScopedResource()
        do { try ArchivePublisher.validateDestination(destination) }
        catch {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            status = error.localizedDescription
            return
        }
        // Same-volume staging permits atomic publication without truncating an
        // existing archive when the helper fails or is cancelled.
        let work = destination.deletingLastPathComponent().appendingPathComponent(".storagedaddy-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let log = work.appendingPathComponent("helper.log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ArchivePublicationError.publishFailed
            }
            let logHandle = try FileHandle(forWritingTo: log)
            let worker = Process()
            worker.executableURL = helper
            let home = FileManager.default.homeDirectoryForCurrentUser
            worker.arguments = ["--no-history", "--include-subagents", "--source", provider == .all ? "all" : provider.rawValue.lowercased(),
                                "--claude-dir", home.appendingPathComponent(".claude").path,
                                "--codex-dir", home.appendingPathComponent(".codex").path,
                                "--modified-before", String(cutoff.timeIntervalSince1970),
                                "--receipt", work.appendingPathComponent("receipt.json").path,
                                "--output", work.appendingPathComponent("archive.zip").path]
            worker.standardOutput = logHandle
            worker.standardError = logHandle
            worker.terminationHandler = { [weak self] finished in
                let exitCode = finished.terminationStatus
                Task { @MainActor in
                    try? logHandle.close()
                    await self?.finish(exitCode: exitCode, work: work, destination: destination, scoped: scoped, cutoff: cutoff)
                }
            }
            completed = nil; cancellationRequested = false
            reviewCleanup = false; cleanupAcknowledged = false; cleanupFinished = false; trashedURLs = []
            started = Date(); busy = true; status = "Reading older session files and building your archive…"
            process = worker
            do { try worker.run() }
            catch {
                try? logHandle.close()
                process = nil; busy = false; status = "The archiving helper could not start. Your sessions are unchanged."
                if scoped { destination.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: work)
            }
        } catch {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            status = "Could not create the archive there. Choose another folder or check available space."
            try? FileManager.default.removeItem(at: work)
        }
    }

    func cancel() {
        guard busy else { return }
        cancellationRequested = true
        status = "Stopping export…"
        process?.terminate()
    }

    private func finish(exitCode: Int32, work: URL, destination: URL, scoped: Bool, cutoff: Date) async {
        defer {
            process = nil; busy = false
            try? FileManager.default.removeItem(at: work)
            if scoped { destination.stopAccessingSecurityScopedResource() }
        }
        if cancellationRequested { status = "Export cancelled. Your sessions and existing archives are unchanged."; return }
        guard exitCode == 0 else {
            status = "Export stopped because a session changed, could not be read, or the destination became unavailable. Your originals are unchanged."
            return
        }
        do {
            let receipt = try ConversationArchiveReceipt.read(from: work.appendingPathComponent("receipt.json"))
            guard receipt.sessions > 0 else {
                status = "No conversations found before this date. Try a later date or another provider. No archive was saved."
                return
            }
            let staged = work.appendingPathComponent("archive.zip")
            let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            try ArchivePublisher.publish(staged: staged, destination: destination)
            status = "Archive saved. Verifying its contents and original session files…"
            let cleanup = await Task.detached(priority: .userInitiated) {
                try? ArchiveCleanupVerifier.prepare(receipt: receipt, archive: destination, cutoff: cutoff)
            }.value
            completed = Completed(receipt: receipt, url: destination, bytes: bytes,
                                  elapsed: Date().timeIntervalSince(started ?? Date()), cleanup: cleanup)
            status = cleanup == nil
                ? "Archive saved, but original cleanup could not be verified. Your originals are unchanged."
                : "Archive verified. Review originals separately if you want to clean up."
        } catch { status = "Could not finish the export. Your sessions and existing archives are unchanged. Try another destination." }
    }

    func trashVerifiedOriginals() {
        guard !busy, !cleanupFinished, cleanupAcknowledged, let plan = completed?.cleanup else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(plan.items.count.formatted()) original session files to Trash?"
        alert.informativeText = "The compact archive keeps conversations, not full resumable histories. Tool payloads, attachments, reasoning and unsupported records are omitted. Close sessions using these files before continuing. The archive and every original will be checked again. Trash continues to use disk space until you empty it yourself."
        alert.addButton(withTitle: "Keep Originals")
        alert.addButton(withTitle: "Move Originals to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; started = Date(); status = "Rechecking the archive and each original…"
        Task {
            defer { busy = false }
            var moved = 0
            do {
                var validatedPlan = try await Task.detached(priority: .userInitiated) { try ArchiveCleanupVerifier.validate(plan) }.value
                trashedURLs = []
                for item in plan.items {
                    // Validate immediately before each recoverable move. Filesystem
                    // mutation is not atomic; stop on the first failure and report it.
                    let previousPlan = validatedPlan
                    validatedPlan = try await Task.detached(priority: .userInitiated) {
                        let refreshed = try ArchiveCleanupVerifier.validateArchiveIdentity(previousPlan)
                        try ArchiveCleanupVerifier.validateItem(item)
                        return refreshed
                    }.value
                    var result: NSURL?
                    try ArchiveCleanupVerifier.validateIdentity(item)
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.source.path), resultingItemURL: &result)
                    moved += 1
                    if let result { trashedURLs.append(result as URL) }
                }
                didMoveOriginals()
                cleanupFinished = true; reviewCleanup = false
                status = "\(plan.items.count.formatted()) originals moved to Trash. Your verified archive is saved. Space is freed only when Trash is emptied."
            } catch {
                if moved > 0 { didMoveOriginals() }
                cleanupFinished = true
                status = moved == 0 ? "Nothing moved. \(error.localizedDescription) Export again to start a new review." : "Stopped after \(moved.formatted()) files moved to Trash. The rest remain in place. \(error.localizedDescription) Export remaining originals again to start a new review."
            }
        }
    }
}

struct ConversationArchiveView: View {
    @ObservedObject var model: ConversationArchiveModel
    let inventory: AISessionInventoryReport?

    private struct Estimate {
        let sessions: [AISessionRecord]
        var allocatedBytes: Int64 { sessions.reduce(0) { $0 + $1.allocatedBytes } }
        var logicalBytes: Int64 { sessions.reduce(0) { $0 + $1.logicalBytes } }
        func records(for provider: AISessionProvider) -> [AISessionRecord] {
            sessions.filter { $0.provider == provider }
        }
    }

    private var estimate: Estimate? {
        inventory.map { report in
            let cutoff = Calendar.current.startOfDay(for: model.before)
            return Estimate(sessions: report.sessions.filter { session in
                guard session.modified < cutoff else { return false }
                switch model.provider {
                case .all: return true
                case .codex: return session.provider == .codex
                case .claude: return session.provider == .claude
                }
            })
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if geometry.size.width >= 930 {
                        HStack(alignment: .top, spacing: 20) {
                            planColumn
                                .frame(minWidth: 500, maxWidth: .infinity, alignment: .topLeading)
                            summaryColumn
                                .frame(width: 340, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            planColumn
                            summaryColumn
                        }
                    }
                    statusSection
                    if let completed = model.completed { receipt(completed) }
                }
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 24)
            }
        }
    }

    private var planColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ARCHIVE PLAN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Tints.mint)
                Text("Make old conversations lighter.")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("Save a compact reading copy of older Claude and Codex conversations. Your recent sessions and every original stay where they are.")
                    .foregroundStyle(Tints.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stepCard("1", "Choose the agents", "Include one history or combine both.", color: Tints.mint) {
                HStack(spacing: 9) {
                    ForEach(ConversationArchiveModel.Provider.allCases, id: \.self) { provider in
                        Button { model.provider = provider } label: {
                            HStack(spacing: 6) {
                                if let iconProvider = provider.sessionProvider {
                                    AIProviderIcon(provider: iconProvider, size: 16)
                                }
                                Text(provider.rawValue)
                            }
                        }
                            .buttonStyle(StorageButtonStyle(prominent: model.provider == provider))
                    }
                }
                .disabled(model.busy)
            }

            stepCard("2", "Choose an age", "Sessions modified before the cutoff qualify.", color: Tints.mint) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        presetButton("30 days", days: 30)
                        presetButton("3 months", days: 90)
                        presetButton("1 year", days: 365)
                    }
                    HStack(spacing: 12) {
                        Text("Exact cutoff")
                            .font(.caption)
                            .foregroundStyle(Tints.secondaryText)
                        Spacer()
                        DatePicker("Archive sessions modified before", selection: $model.before, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .fixedSize()
                            .accessibilityLabel("Archive sessions modified before")
                    }
                }
                .disabled(model.busy)
            }

            stepCard("3", "Save the archive", selectionSentence, color: Tints.mint) {
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: model.chooseDestination) {
                        Label("Choose location and export", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StorageButtonStyle(prominent: true))
                    .disabled(!exportEnabled)
                    Text("Desktop is suggested. You can save the ZIP anywhere you choose.")
                        .font(.caption)
                        .foregroundStyle(Tints.secondaryText)
                    if model.busy, model.cancellable {
                        Button("Cancel Export", systemImage: "xmark", action: model.cancel)
                    }
                }
            }
        }
    }

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionCard
            infoCard(
                "The archive keeps",
                icon: "text.bubble",
                color: Tints.mint,
                lines: ["Prompts and replies", "Project and session details", "Readable conversation metadata"]
            )
            infoCard(
                "It leaves out",
                icon: "eye.slash",
                color: Tints.secondaryText,
                lines: ["Tool payloads and attachments", "Reasoning traces", "Unsupported or malformed records"]
            )
            VStack(alignment: .leading, spacing: 8) {
                Label("Originals stay untouched", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(Tints.mint)
                Text("Exporting frees no space. After verification, removing originals is a separate review with its own confirmation.")
                    .font(.callout)
                    .foregroundStyle(Tints.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Runs locally with Memory Pack. No AI calls or uploads.")
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
            }
            .padding(16)
            .background(AppColors.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.28)))
        }
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("YOUR SELECTION")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Tints.mint)
            if let estimate {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(estimate.sessions.count.formatted())
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(estimate.sessions.count == 1 ? "transcript file" : "transcript files")
                        .foregroundStyle(Tints.secondaryText)
                }
                Text("modified before \(model.before.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
                HStack(spacing: 18) {
                    summaryMetric("ON DISK", displayBytes(estimate.allocatedBytes), Tints.mint)
                    summaryMetric("LOGICAL", displayBytes(estimate.logicalBytes), Tints.cyan)
                }
                providerRow(.claude, estimate: estimate, color: Tints.coral)
                providerRow(.codex, estimate: estimate, color: Tints.electricBlue)
                Text("Estimate from transcript-file metadata. The verified export receipt is final.")
                    .font(.caption2)
                    .foregroundStyle(Tints.secondaryText)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading local session metadata…")
                        .foregroundStyle(Tints.secondaryText)
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.28)))
    }

    @ViewBuilder private var statusSection: some View {
        if !model.available {
            Label("The archiving helper is missing from this build. Install a complete storagedaddy app to export conversations.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Tints.yellow)
        }
        if model.busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.status)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(SpeedFormat.duration(context.date.timeIntervalSince(model.started ?? context.date))).monospacedDigit()
                }
            }
            .padding(14)
            .foregroundStyle(Tints.secondaryText)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.25)))
        } else if !model.status.isEmpty {
            Text(model.status)
                .foregroundStyle(model.completed == nil ? Tints.secondaryText : Tints.mint)
                .padding(.vertical, 4)
        }
    }

    private var selectionSentence: String {
        guard let estimate else { return "storagedaddy is finding the transcript files that match this plan." }
        guard !estimate.sessions.isEmpty else { return "No transcript files match yet. Choose a later cutoff or another agent." }
        return "About \(displayBytes(estimate.allocatedBytes)) across \(estimate.sessions.count.formatted()) transcript files will be read into one compact ZIP."
    }

    private var exportEnabled: Bool {
        guard !model.busy, model.available, let estimate else { return false }
        return !estimate.sessions.isEmpty || inventory?.coverage.isPartial == true
    }

    private func displayBytes(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : DiskFormat.bytes(bytes)
    }

    private func presetButton(_ title: String, days: Int) -> some View {
        Button(title) { model.before = presetDate(days: days) }
            .buttonStyle(StorageButtonStyle(prominent: Calendar.current.isDate(model.before, inSameDayAs: presetDate(days: days))))
    }

    private func presetDate(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }

    private func stepCard<Content: View>(
        _ number: String,
        _ title: String,
        _ detail: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(AppColors.canvas)
                .frame(width: 26, height: 26)
                .background(color, in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Tints.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(AppColors.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.2)))
    }

    private func infoCard(_ title: String, icon: String, color: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(line).font(.callout).foregroundStyle(Tints.secondaryText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.18)))
    }

    private func summaryMetric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(color)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func providerRow(_ provider: AISessionProvider, estimate: Estimate, color: Color) -> some View {
        let records = estimate.records(for: provider)
        let bytes = records.reduce(0) { $0 + $1.allocatedBytes }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                AIProviderIcon(provider: provider, size: 20)
                Text(provider.rawValue).font(.callout.weight(.medium))
                Spacer()
                Text("\(records.count.formatted()) · \(displayBytes(bytes))")
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.22))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: max(records.isEmpty ? 0 : 4, geometry.size.width * providerFraction(bytes, total: estimate.allocatedBytes)))
                    }
            }
            .frame(height: 6)
        }
    }

    private func providerFraction(_ bytes: Int64, total: Int64) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(bytes) / Double(total))
    }

    private func receipt(_ result: ConversationArchiveModel.Completed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your archive is ready", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(Tints.mint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 20)], alignment: .leading, spacing: 14) {
                metric("Source text", DiskFormat.bytes(result.receipt.sourceBytes))
                metric("Compact archive", DiskFormat.bytes(result.bytes))
                metric("Export time", SpeedFormat.duration(result.elapsed))
                if result.bytes > 0 { metric("Size reduction", String(format: "%.1f×", Double(result.receipt.sourceBytes) / Double(result.bytes))) }
            }
            Text("\(result.receipt.sessions.formatted()) sessions · \(result.receipt.prompts.formatted()) prompts · \(result.receipt.messages.formatted()) messages")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            if result.receipt.skippedFiles > 0 {
                Text("\(result.receipt.skippedFiles.formatted()) files excluded by the date or read checks. This is a selection, not a complete backup.")
                    .font(.caption).foregroundStyle(Tints.yellow)
            }
            if let rss = result.receipt.peakRSSBytes {
                Text("\(DiskFormat.bytes(Int64(clamping: rss))) helper peak RSS").font(.caption).foregroundStyle(Tints.secondaryText)
            }
            Text(result.url.lastPathComponent).lineLimit(1).truncationMode(.middle).help(result.url.path)
            Button("Show Archive in Finder", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
            if let plan = result.cleanup, !model.cleanupFinished {
                Button(model.reviewCleanup ? "Hide Original Review" : "Review Originals for Cleanup…", systemImage: "checkmark.shield") {
                    model.reviewCleanup.toggle()
                }.disabled(model.busy)
                if model.reviewCleanup {
                    Text("\(plan.items.count.formatted()) verified originals · \(DiskFormat.bytes(plan.sourceBytes)) of source text")
                        .font(.headline)
                    Text("Only files represented in this export are listed. Changed files block cleanup. This does not guarantee these sessions are inactive: close them before proceeding.")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(plan.items, id: \.source.path) { item in
                                HStack {
                                    Text(URL(fileURLWithPath: item.source.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                        .help(item.source.path)
                                    Spacer()
                                    Text(DiskFormat.bytes(item.source.size)).monospacedDigit()
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.source.path)]) }
                                }.font(.caption)
                            }
                        }
                    }.frame(maxHeight: 180)
                    Toggle("I no longer need to resume these sessions, and accept the omitted data.", isOn: $model.cleanupAcknowledged)
                    Button("Move Verified Originals to Trash…", systemImage: "trash", action: model.trashVerifiedOriginals)
                        .buttonStyle(StorageButtonStyle(prominent: true))
                        .disabled(!model.cleanupAcknowledged || model.busy)
                }
            }
            if !model.trashedURLs.isEmpty {
                Button("Show Originals in Trash", systemImage: "trash") { NSWorkspace.shared.activateFileViewerSelecting(model.trashedURLs) }
                Text("To recover an original, use Finder’s Put Back action in Trash.").font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.35)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(Tints.secondaryText)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}
