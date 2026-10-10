import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 210, ideal: 230)
    } detail: {
      DetailView(page: model.page ?? .overview)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if model.pendingCount > 0 { PendingBar() }
        }
    }
    .sheet(isPresented: $model.reviewing) { ReviewSheet() }
    .sheet(isPresented: Binding(get: { model.run != nil }, set: { if !$0 { model.dismissRun() } })) {
      RunSheet()
    }
  }
}

struct DetailView: View {
  let page: Page

  var body: some View {
    switch page {
    case .overview: OverviewView()
    case .intelligence: IntelligenceView()
    case .group(let group): TweakGroupView(group: group)
    case .background: BackgroundView()
    case .storage: StorageView()
    case .changes: ChangesView()
    }
  }
}

// MARK: - Sidebar

struct Sidebar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    List(selection: $model.page) {
      row(.overview, badge: 0)
      Section("Debloat") {
        row(.intelligence, badge: model.aiPending ? 1 : 0)
        ForEach(TweakGroup.allCases) { group in
          row(.group(group), badge: model.pending(in: group))
        }
        row(.background, badge: 0)
      }
      Section("Clean Up") {
        row(.storage, badge: 0)
        row(.changes, badge: 0)
      }
    }
    .listStyle(.sidebar)
  }

  func row(_ page: Page, badge: Int) -> some View {
    Label(page.title, systemImage: page.symbol)
      .badge(badge)
      .tag(page)
  }
}

// MARK: - Bottom bar and review

struct PendingBar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.tint)
      Text(model.pendingCount == 1 ? "1 change to apply" : "\(model.pendingCount) changes to apply")
        .font(.callout.weight(.medium))
      Spacer()
      Button("Discard") { model.discard() }
      Button("Review and Apply…") { model.reviewing = true }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}

struct ReviewSheet: View {
  @Environment(AppModel.self) private var model
  @State private var plan: Plan?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Review changes").font(.title2.weight(.semibold))
        Text("Nothing changes until you click Apply. Settings can be undone; removed models download again when you enable their features.")
          .foregroundStyle(.secondary)
      }
      .padding(20)
      Divider()
      if let plan {
        List {
          if !plan.apply.isEmpty {
            Section("Apply") {
              ForEach(plan.apply) { t in ChangeRow(tweak: t, adding: true) }
            }
          }
          if !plan.revert.isEmpty {
            Section("Undo") {
              ForEach(plan.revert) { t in ChangeRow(tweak: t, adding: false) }
            }
          }
          if model.aiPending || !plan.models.isEmpty {
            Section("Apple Intelligence") {
              if model.aiPending, let kept = model.targetAI {
                Label(
                  kept.isEmpty ? "Turn off every feature" : "Turn off everything except \(kept.count) kept feature\(kept.count == 1 ? "" : "s")",
                  systemImage: "apple.intelligence")
              } else if model.aiPending {
                Label("Turn Apple Intelligence back on. macOS downloads its models again when a feature needs them.", systemImage: "arrow.uturn.backward")
              }
              if !plan.models.isEmpty {
                let bytes = model.modelBytes(plan.models)
                Label(
                  bytes.map { $0 > 0 ? "Delete the models, about \(Term.size($0))" : "Ask macOS to finish removing leftover model files" }
                    ?? "Delete the models",
                  systemImage: "trash")
              }
            }
          }
          if let profile = plan.profile {
            Section("Approval") {
              Label(
                profile.isEmpty
                  ? "Remove the StorageDaddy profile in System Settings."
                  : "Approve the StorageDaddy profile in System Settings. macOS asks for this click. The locked settings change once you do.",
                systemImage: "checkmark.shield")
            }
          }
        }
        .listStyle(.inset)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.reviewing = false }
          .keyboardShortcut(.cancelAction)
        Button("Apply") { if let plan { model.apply(plan) } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(plan?.isEmpty ?? true)
      }
      .padding(16)
    }
    .frame(width: 600, height: 560)
    .task {
      let wanted = model.wanted
      let ai = model.targetAI
      let snapshot = model.snapshot
      let undo = model.touched
      plan = await Task.detached { Plan.make(wanted: wanted, ai: ai, undo: undo, snapshot: snapshot) }.value
    }
  }
}

struct ChangeRow: View {
  let tweak: Tweak
  let adding: Bool
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(tweak.changes.indices, id: \.self) { i in
          Text(tweak.changes[i].command)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(.vertical, 4)
    } label: {
      HStack {
        Image(systemName: adding ? "plus.circle.fill" : "arrow.uturn.backward.circle.fill")
          .foregroundStyle(adding ? Color.accentColor : .orange)
        Text(tweak.title)
        if tweak.inProfile {
          Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            .help("Locked by the StorageDaddy profile")
        }
      }
    }
  }
}

// MARK: - Running

struct RunSheet: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 18) {
      switch model.run {
      case .working(let text)?:
        ProgressView().controlSize(.large)
        Text(text).font(.headline)
      case .approveProfile(let remove)?:
        Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(.tint)
        Text(remove ? "Remove the profile in System Settings" : "Approve the profile in System Settings")
          .font(.title3.weight(.semibold))
        VStack(alignment: .leading, spacing: 8) {
          if remove {
            step(1, "In Device Management, select StorageDaddy Apple Intelligence.")
            step(2, "Click the minus button or Remove, then enter your password.")
          } else {
            step(1, "Under Downloaded, double-click StorageDaddy Apple Intelligence.")
            step(2, "Click Install, then enter your password.")
          }
        }
        .frame(maxWidth: 360, alignment: .leading)
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Waiting for System Settings…").foregroundStyle(.secondary)
        }
        Text("If System Settings says the profile couldn't be installed, click Cancel and report it on GitHub.")
          .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 340)
        HStack {
          Button("Cancel") { model.cancel() }
          Button("Open System Settings") { Commands.openProfileSettings() }
            .buttonStyle(.borderedProminent)
        }
      case .finished(let problems, let freed)?:
        Image(systemName: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.system(size: 44))
          .foregroundStyle(problems.isEmpty ? Color.green : Color.orange)
        Text(problems.isEmpty ? "Done" : "Finished with problems").font(.title3.weight(.semibold))
        if let freed, freed > 0 {
          Text("Deleted \(Term.size(freed)) of models. macOS removes the files on its own schedule, so Storage settings can count them for a while.")
            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
        }
        if !problems.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(problems, id: \.self) { Text("• " + $0).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: 420, maxHeight: 160)
        }
        Button("Done") { model.dismissRun() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      case nil:
        EmptyView()
      }
    }
    .padding(28)
    .frame(width: 460)
    .interactiveDismissDisabled()
  }

  func step(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(n)").font(.callout.weight(.semibold).monospacedDigit())
        .frame(width: 22, height: 22)
        .background(Circle().fill(.quaternary))
      Text(text)
    }
  }
}
