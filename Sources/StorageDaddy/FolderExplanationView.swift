import SwiftUI
import DiskCore

struct FolderExplanationView: View {
    let state: FolderExplanationState
    @EnvironmentObject var m: ExplorerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Tints.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder Explanation").font(.headline)
                    Text(state.folderPath).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Done") { m.dismissFolderExplanation() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider().overlay(Tints.secondaryText.opacity(0.18))
            content
            Divider().overlay(Tints.secondaryText.opacity(0.18))
            HStack {
                Text("storagedaddy sent only this folder's path and measurements to your local \(state.agentLabel) install. The agent ran read-only.")
                    .font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(2)
                Spacer()
                if case .success(let result) = state.result {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    }
                }
            }.padding(16)
        }
        .frame(width: 640, height: 520)
        .background(AppColors.canvas)
        .buttonStyle(StorageButtonStyle())
    }

    @ViewBuilder private var content: some View {
        switch state.result {
        case .none:
            VStack(spacing: 12) {
                ProgressView()
                Text("Asking \(state.agentLabel)…").font(.callout)
                Text("This can take a minute. The agent can only read files; it cannot change anything.")
                    .font(.caption).foregroundStyle(Tints.secondaryText).multilineTextAlignment(.center)
                Button("Cancel") { m.dismissFolderExplanation() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        case .success(let result):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(result.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Answered in \(result.elapsed.formatted(.number.precision(.fractionLength(0...1))))s by \(state.agentLabel)")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }.padding(20)
            }
        case .failure(let error):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(Tints.yellow)
                Text(Self.describe(error)).font(.callout).multilineTextAlignment(.center)
                Button("Copy Prompt Instead") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.prompt, forType: .string)
                    m.dismissFolderExplanation()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let failure = error as? FolderExplanationError else {
            return "The agent could not explain this folder. \(error.localizedDescription)"
        }
        switch failure {
        case .launchFailed(let detail):
            return "The agent could not start. \(detail)"
        case .nonZeroExit(let code, let detail):
            return detail.isEmpty ? "The agent exited with code \(code)." : "The agent exited with code \(code): \(detail)"
        case .timedOut:
            return "The agent took too long to answer and was stopped."
        case .emptyOutput:
            return "The agent finished without an explanation."
        case .cancelled:
            return "The explanation was cancelled."
        }
    }
}
