import SwiftUI
import AppKit
import SaaSMakerUI
import AgentBridge

struct AgentAccessView: View {
    @ObservedObject var agents: AgentAccessModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        SMSectionHeader("AI Agents", size: 28)
                        Text("Let a local assistant read scans and help prepare cleanup.").foregroundStyle(Tints.secondaryText)
                    }
                    Spacer()
                    DoodleArt(topic: .agents).frame(width: 80, height: 80)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Allow local AI agents", isOn: Binding(get: { agents.enabled }, set: agents.setEnabled))
                        .tint(Tints.mint).font(.headline)
                    Text(agents.listening ? "Listening locally for Codex OAuth and the private stdio bridge." : "Off. Nothing listens until you turn this on.")
                        .foregroundStyle(Tints.secondaryText)
                    Text("Each client needs your approval. File contents are never exposed. Every removal stays in native review until you decide.")
                        .font(.callout).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                }.padding(20).storagePanel()
                if let error = agents.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tints.yellow).textSelection(.enabled) }
                if agents.enabled {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect an agent").font(.title3.weight(.semibold))
                        Text("Copy the command for Codex or Claude Code. StorageDaddy never changes another app’s configuration.").foregroundStyle(Tints.secondaryText)
                        Text(agents.configuration).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy commands", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(agents.configuration, forType: .string) }
                        HStack {
                            Button(agents.extensionWorking ? "Preparing extension…" : "Add to Claude Desktop", action: agents.addToClaudeDesktop).disabled(agents.extensionWorking)
                            if let file = agents.extensionURL { Button("Show extension") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
                        }
                        Text("Other MCP clients can launch the same helper with no arguments. Keychain keeps approved credentials; use --ephemeral for a connection that is never saved.").font(.caption).foregroundStyle(Tints.secondaryText)
                        Text("HTTP clients sign in again after AI Agents is turned off or StorageDaddy restarts. The private stdio helper keeps its Keychain approval.").font(.caption).foregroundStyle(Tints.secondaryText)
                    }.padding(20).storagePanel()
                }
                ForEach(agents.pairings) { request in
                    AgentApprovalCard(request: request, agents: agents)
                }
                if !agents.sessions.isEmpty {
                    HStack { Text("Approved sessions").font(.title3.weight(.semibold)); Spacer(); Button("Forget revoked", action: agents.forgetRevoked) }
                    ForEach(agents.sessions) { session in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(session.name, systemImage: session.revokedAt == nil ? "checkmark.shield" : "xmark.shield").font(.headline)
                                Spacer()
                                if session.revokedAt == nil {
                                    Picker("Role", selection: Binding(get: { session.role }, set: { agents.setRole(session.id, role: $0) })) {
                                        ForEach(AgentRole.allCases) { Text($0.title).tag($0) }
                                    }.labelsHidden().frame(maxWidth: 220)
                                    Button("Revoke") { agents.revoke(session.id) }
                                } else { Text("Revoked").foregroundStyle(Tints.secondaryText) }
                            }
                            Text(session.permissions.sorted().joined(separator: " · ")).font(.caption).foregroundStyle(Tints.secondaryText)
                            if let connection = session.connection { Text(connection).font(.caption).foregroundStyle(Tints.secondaryText).textSelection(.enabled) }
                            if let action = session.lastAction { Text(action + " · \(session.blocked) blocked").font(.caption).foregroundStyle(Tints.secondaryText) }
                        }.padding(18).storagePanel()
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Scan access").font(.title3.weight(.semibold)); Spacer(); Button("Allow current scan root", action: agents.approveCurrentRoot) }
                    Text("Agents can scan only these exact locations. Add a location by scanning it yourself, then allowing the current root here.").font(.callout).foregroundStyle(Tints.secondaryText)
                    ForEach(agents.approvedRoots, id: \.self) { root in
                        HStack { Text(root).font(.caption).textSelection(.enabled); Spacer(); Button("Remove") { agents.removeRoot(root) } }
                    }
                }.padding(20).storagePanel()
                if !agents.reviews.isEmpty {
                    Text("Removal requests · \(agents.waitingReviewCount) waiting").font(.title3.weight(.semibold))
                    Text("Review sends one item to the existing Cleanup preflight. Nothing moves until you approve Cleanup. Check the final action there.").foregroundStyle(Tints.secondaryText)
                    ForEach(agents.reviews.reversed()) { request in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(request.permanent ? "Permanent deletion requested" : "Trash requested", systemImage: "tray.full")
                                    .foregroundStyle(request.permanent ? Color.red : Tints.mint).font(.headline)
                                Spacer()
                                if request.pending {
                                    Button("Skip") { agents.skipReview(request.id) }
                                    Button("Review in Cleanup") { agents.review(request.id) }
                                }
                            }
                            Text(request.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            Text(request.agent + " · " + request.reason).font(.callout).foregroundStyle(Tints.secondaryText)
                            Text(request.outcome).font(.caption).foregroundStyle(Tints.secondaryText)
                        }.padding(18).storagePanel()
                    }
                }
                if !agents.audit.isEmpty {
                    Text("Recent agent actions").font(.title3.weight(.semibold))
                    ForEach(agents.audit.prefix(30)) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: entry.blocked ? "hand.raised" : "clock").foregroundStyle(entry.blocked ? Color.red : Tints.mint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.session + " · " + entry.action).font(.callout)
                                Text(entry.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Tints.secondaryText)
                            }
                            Spacer()
                        }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(AppColors.canvas).buttonStyle(StorageButtonStyle())
    }
}

private struct AgentApprovalCard: View {
    let request: AgentPairing
    @ObservedObject var agents: AgentAccessModel
    @State private var role = AgentRole.guide
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Waiting for approval", systemImage: "person.badge.key").font(.headline).foregroundStyle(Tints.yellow)
            Text(request.client).font(.title3.weight(.semibold))
            Text(request.connection).font(.caption.monospaced()).foregroundStyle(Tints.secondaryText).textSelection(.enabled)
            Text("This name was provided by the client. Approve only the connection you just started on this Mac.").font(.callout).foregroundStyle(Tints.secondaryText)
            TextField("Session name", text: $name)
            Picker("Role", selection: $role) { ForEach(AgentRole.allCases) { Text($0.title).tag($0) } }
            Text(role.permissions.sorted().joined(separator: " · ")).font(.caption).foregroundStyle(Tints.secondaryText)
            if role == .operator || role == .admin {
                Text(role == .admin ? "Can request permanent deletion. You must still review every item and approve Cleanup." : "Can request moving items to Trash. You must still review every item and approve Cleanup.")
                    .font(.callout).foregroundStyle(role == .admin ? Color.red : Tints.yellow)
            }
            HStack {
                Button("Deny") { agents.deny(request.id) }
                Spacer()
                Button("Approve \(role.title)") { agents.approve(request.id, role: role, name: name) }.buttonStyle(StorageButtonStyle(prominent: true))
            }
        }.padding(20).storagePanel().onAppear { name = request.client }
    }
}
