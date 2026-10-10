import SwiftUI

// MARK: - Overview

struct OverviewView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        StatusRow(
          symbol: "apple.intelligence", title: "Apple Intelligence",
          value: aiText, good: model.currentAI != nil
        ) { model.page = .intelligence }
        StatusRow(
          symbol: "slider.horizontal.3", title: "Tweaks",
          value: "\(model.appliedCount) of \(model.availableCount) applied", good: model.appliedCount > 0
        ) { model.page = .group(.privacy) }
        StatusRow(
          symbol: "gearshape.2", title: "Background items from other apps",
          value: backgroundText, good: model.background.isEmpty || !model.backgroundOff.isEmpty
        ) { model.page = .background }
        StatusRow(
          symbol: "internaldrive", title: "Space you can get back",
          value: model.scanned ? Term.size(model.storage.reduce(0) { $0 + $1.bytes }) : "Not scanned yet", good: false
        ) { model.page = .storage }
      } header: {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Debloat this Mac")
              .font(.system(size: 28, weight: .bold))
              .foregroundStyle(.primary)
            Text("Turn off Apple Intelligence, analytics and the pop-ups macOS adds, and get disk space back. You see every change before it happens, and you can undo settings changes later.")
              .font(.body)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text("Apple Intelligence removal builds on [pared](https://github.com/4evy/pared) by 4evy.")
              .font(.callout)
              .foregroundStyle(.tertiary)
              .tint(.secondary)
          }
          Text("This Mac")
        }
        .textCase(nil)
        .padding(.top, 4)
      }

      Section {
        ForEach(Preset.allCases) { preset in
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: preset == .recommended ? "checkmark.seal" : "hand.raised")
              .font(.title2).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
              Text(preset.title).font(.headline)
              Text(preset.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              Text("\(Tweaks.preset(preset).count) tweaks and Apple Intelligence off")
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Choose…") {
              model.choose(preset)
              model.reviewing = true
            }
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("Start with a preset")
      } footer: {
        Footer("A preset adds to what's already applied and changes nothing until you review it. Pick single tweaks from the Section menu.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Overview")
  }

  var aiText: String {
    if model.loadingModels { return "Checking…" }
    let amount = model.modelBytes(Catalog.modelSets.map(\.name)).map(Term.size) ?? "unknown model size"
    if model.currentAI != nil { return "Off · " + amount }
    let on = model.featureStates.values.filter { $0 == .on }.count
    return "\(on) features on · " + amount
  }

  var backgroundText: String {
    let n = model.background.count
    if n == 0 { return "None" }
    let off = model.backgroundOff.count
    return off > 0 ? "\(n), \(off) turned off" : "\(n) configured"
  }
}

struct StatusRow: View {
  let symbol: String
  let title: String
  let value: String
  let good: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
        Text(title)
        Spacer()
        Text(value).foregroundStyle(good ? Color.green : Color.secondary)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Apple Intelligence

struct IntelligenceView: View {
  @Environment(AppModel.self) private var model
  @State private var confirmingModels = false

  var body: some View {
    @Bindable var model = model
    Form {
      Section {
        Toggle(isOn: $model.aiOff) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Turn off Apple Intelligence").font(.headline)
            Text("Turns off Siri, Writing Tools, Genmoji, Image Playground, summaries and ChatGPT, deletes the models and stops macOS downloading them again.")
              .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        .toggleStyle(.switch)
      } footer: {
        Footer("macOS asks you to approve a configuration profile for this. Remove the profile to restore your own settings. This part builds on pared by 4evy, which first mapped Apple's asset service and model sets.")
      }

      Section {
        ForEach(Catalog.features, id: \.id) { feature in
          Toggle(isOn: Binding(
            get: { model.aiKept.contains(feature.id) },
            set: { if $0 { model.aiKept.insert(feature.id) } else { model.aiKept.remove(feature.id) } }
          )) {
            VStack(alignment: .leading, spacing: 2) {
              Text(feature.title)
              Text(stateText(feature.id)).font(.caption).foregroundStyle(.secondary)
            }
          }
          .disabled(!model.aiOff)
        }
      } header: {
        Text("Keep these on")
      } footer: {
        Footer("A kept feature keeps the models it needs.")
      }

      Section {
        if model.loadingModels {
          HStack { ProgressView().controlSize(.small); Text("Asking Apple's asset service…").foregroundStyle(.secondary) }
        } else if !model.modelsAvailable {
          Text("Apple's asset service didn't answer, so the sizes are unknown.").foregroundStyle(.secondary)
        } else {
          ForEach(Catalog.modelSets, id: \.name) { set in
            LabeledContent(set.title) {
              let bytes = model.modelBytes[set.name]
              Text(bytes.map { $0 > 0 ? Term.size($0) : "None" } ?? "Unknown").foregroundStyle(.secondary)
            }
          }
          LabeledContent("Total") { Text(model.modelBytes(Catalog.modelSets.map(\.name)).map(Term.size) ?? "Unknown").fontWeight(.semibold) }
          if model.currentAI != nil && model.modelTotal > 0 {
            HStack {
              Text("Apple Intelligence is off, but these models are still on disk.").foregroundStyle(.secondary)
              Spacer()
              Button("Review Model Removal…") { confirmingModels = true }
            }
          }
        }
      } header: {
        Text("Models on disk")
      } footer: {
        Footer("macOS deletes the files on its own schedule, so Storage settings can count them for a while after removal.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Apple Intelligence")
    .confirmationDialog("Remove the models for disabled features?", isPresented: $confirmingModels) {
      Button("Remove Models", role: .destructive) { model.deleteLeftoverModels() }
    } message: {
      Text("Models required by kept features stay. Removal goes through Apple’s asset service, not the Trash. Remove the StorageDaddy profile and enable features to download them again.")
    }
  }

  func stateText(_ id: String) -> String {
    switch model.featureStates[id] {
    case .lockedOff?: return "Off, locked by StorageDaddy"
    case .off?: return "Off"
    case .on?: return "On"
    default: return model.loadingModels ? "Checking…" : "Unknown"
    }
  }
}

// MARK: - Tweak groups

struct TweakGroupView: View {
  @Environment(AppModel.self) private var model
  let group: TweakGroup

  var tweaks: [Tweak] { Tweaks.all.filter { $0.group == group } }

  var body: some View {
    Form {
      Section {
        ForEach(tweaks) { TweakRow(tweak: $0) }
      } header: {
        Text(group.summary).font(.body).foregroundStyle(.secondary).textCase(nil)
      } footer: {
        if tweaks.contains(where: \.inProfile) {
          Footer("Settings with a lock are applied by the StorageDaddy profile, which macOS asks you to approve.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(group.title)
    .toolbar {
      ToolbarItem {
        Menu {
          Button("Select All") { for t in tweaks where t.supported { model.toggle(t, true) } }
          Button("Select Recommended") {
            for t in tweaks {
              let recommended = t.presets.contains(.recommended)
              if model.state(t) == .partial && !recommended {
                model.leave(t)
              } else {
                model.toggle(t, recommended || model.state(t) == .applied)
              }
            }
          }
          Button("Deselect All") { for t in tweaks { model.toggle(t, false) } }
        } label: {
          Label("Select", systemImage: "checklist")
        }
      }
    }
  }
}

struct TweakRow: View {
  @Environment(AppModel.self) private var model
  let tweak: Tweak

  var body: some View {
    let state = model.state(tweak)
    let wanted = model.isOn(tweak)
    Toggle(isOn: Binding(get: { wanted }, set: { model.toggle(tweak, $0) })) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(tweak.title)
          if tweak.inProfile {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
              .help("Locked by the StorageDaddy profile")
          }
          if let note = pendingNote(state: state, wanted: wanted, undoes: model.undoes(tweak)) {
            Text(note).font(.caption.weight(.medium)).foregroundStyle(.tint)
          }
        }
        Text(tweak.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let caveat = tweak.caveat {
          Label(caveat, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        if state == .managed {
          Text("Managed by another profile on this Mac.").font(.caption).foregroundStyle(.secondary)
        } else if state == .unsupported {
          Text("Needs macOS \(tweak.since.0).\(tweak.since.1) or newer.").font(.caption).foregroundStyle(.secondary)
        } else if state == .partial {
          Text("Partly applied. It stays as it is unless you switch it.").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 2)
    }
    .toggleStyle(.switch)
    .disabled(state == .managed || state == .unsupported)
  }

  func pendingNote(state: TweakState, wanted: Bool, undoes: Bool) -> String? {
    if wanted && state != .applied { return "Applies on review" }
    if undoes { return "Undoes on review" }
    return nil
  }
}

// MARK: - Background items

struct BackgroundView: View {
  @Environment(AppModel.self) private var model
  @State private var pending: BackgroundItem?
  @State private var pendingOff = false

  var body: some View {
    Form {
      Section {
        if model.background.isEmpty {
          Text("No background items from other apps.").foregroundStyle(.secondary)
        }
        ForEach(model.background) { item in
          Toggle(isOn: Binding(
            get: { !model.backgroundOff.contains(item.id) },
            set: { pendingOff = !$0; pending = item }
          )) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(item.owner)
                if item.system {
                  Text("All users").font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                }
              }
              Text(item.label).font(.caption.monospaced()).foregroundStyle(.secondary)
              Text(item.program).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
              if let warning = item.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
              }
            }
          }
          .toggleStyle(.switch)
          .disabled(model.backgroundBusy)
        }
      } header: {
        Text("Updaters, helpers and agents other apps installed. They run whether or not their app is open. Every switch asks you to review the change. Turning an updater off stops automatic updates; a helper can be what makes its app work, such as a VPN or Docker.")
          .font(.body).foregroundStyle(.secondary).textCase(nil)
      } footer: {
        Footer("Items marked All users ask for your password. Apple's own background services are protected by System Integrity Protection, so StorageDaddy leaves them alone.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Background Items")
    .confirmationDialog(pendingOff ? "Turn off this background item?" : "Turn on this background item?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
      Button(pendingOff ? "Turn Off" : "Turn On") {
        if let item = pending { model.setBackground(item, off: pendingOff) }
        pending = nil
      }
      Button("Cancel", role: .cancel) { pending = nil }
    } message: {
      if let item = pending {
        Text("\(item.owner) · \(item.label)\n\(item.program)\n" + (pendingOff ? (item.warning ?? "Automatic updates for this app will stop.") : "This item can start running again.") + (item.system ? " This changes the item for all users and requires administrator approval." : ""))
      }
    }
    .toolbar {
      ToolbarItem {
        Button { model.loadBackground() } label: { Label("Reload", systemImage: "arrow.clockwise") }
      }
    }
  }
}

// MARK: - Storage

struct StorageView: View {
  @Environment(AppModel.self) private var model
  @State private var confirming = false

  /// Selected items that are deleted right away instead of going to the Trash.
  var permanentChosen: [String] {
    model.storage.filter { model.storageChosen.contains($0.id) && $0.permanent }.map(\.title)
  }

  var body: some View {
    Form {
      if !model.scanned {
        Section {
          HStack(spacing: 14) {
            Image(systemName: "internaldrive").font(.title).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
              Text("Find space you can get back").font(.headline)
              Text("Looks for old installers, aerial videos, Xcode leftovers, app caches and Time Machine snapshots. Nothing moves until you choose.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.scanning { ProgressView().controlSize(.small) } else { Button("Scan") { model.scan() } }
          }
          .padding(.vertical, 4)
        }
      } else {
        Section {
          if model.storage.isEmpty {
            Text("Nothing to clean up.").foregroundStyle(.secondary)
          }
          ForEach(model.storage) { item in
            HStack(alignment: .top, spacing: 10) {
              Toggle("", isOn: Binding(
                get: { model.storageChosen.contains(item.id) },
                set: { if $0 { model.storageChosen.insert(item.id) } else { model.storageChosen.remove(item.id) } }
              ))
              .toggleStyle(.checkbox)
              .labelsHidden()
              VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Review \(item.paths.count) selected path\(item.paths.count == 1 ? "" : "s")") {
                  ForEach(item.paths, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                  }
                }
                if let caveat = item.caveat {
                  Label(caveat, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(item.kind == .snapshots ? "\(item.count) snapshot\(item.count == 1 ? "" : "s")" : Term.size(item.bytes))
                .monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        } header: {
          HStack {
            Text("Files go to the Trash, so they aren't gone until you empty it. Simulators and snapshots are deleted right away.").textCase(nil)
            Spacer()
            if model.scanning { ProgressView().controlSize(.small) } else { Button("Scan Again") { model.scan() }.buttonStyle(.link) }
          }
        }
        Section {
          HStack {
            if let message = model.cleanMessage {
              Text(message).foregroundStyle(.secondary)
            } else {
              Text(model.storageChosen.isEmpty ? "Nothing selected" : "Selected: \(Term.size(model.chosenBytes))").monospacedDigit()
            }
            Spacer()
            if model.cleaning { ProgressView().controlSize(.small) }
            Button(permanentChosen.isEmpty ? "Move to Trash…" : "Remove…") { confirming = true }
              .buttonStyle(.borderedProminent)
              .disabled(model.storageChosen.isEmpty || model.cleaning)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Storage")
    .confirmationDialog(
      permanentChosen.isEmpty ? "Move the selected items to the Trash?" : "Remove the selected items?",
      isPresented: $confirming
    ) {
      Button(permanentChosen.isEmpty ? "Move to Trash" : "Remove") { model.clean() }
    } message: {
      Text("About \(Term.size(model.chosenBytes)). Items only an administrator can move ask for your password."
        + (permanentChosen.isEmpty ? "" : " \(permanentChosen.joined(separator: " and ")) are deleted right away, not moved to the Trash."))
    }
  }
}

// MARK: - Undo

struct ChangesView: View {
  @Environment(AppModel.self) private var model
  @State private var confirming = false

  var body: some View {
    Form {
      Section("Profile") {
        if model.snapshot.profile.on {
          LabeledContent("StorageDaddy profile", value: "Installed")
          if model.currentAI != nil { Label("Apple Intelligence off", systemImage: "apple.intelligence") }
          ForEach(model.snapshot.profile.tweaks.sorted(), id: \.self) { id in
            Label(Tweaks.tweak(id)?.title ?? id, systemImage: "lock.fill")
          }
        } else {
          Text("Not installed.").foregroundStyle(.secondary)
        }
      }
      Section("Other changes") {
        let entries = model.journal.entries.sorted { $0.value.date > $1.value.date }
        if entries.isEmpty {
          Text("None.").foregroundStyle(.secondary)
        }
        ForEach(entries, id: \.key) { key, entry in
          LabeledContent {
            Text(entry.date, style: .date).foregroundStyle(.secondary)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(title(entry.tweak))
              Text(key).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
          }
        }
      }
      Section {
        HStack {
          Text("Puts every setting back as it was before StorageDaddy changed it, and removes the profile.")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Undo Everything…", role: .destructive) { confirming = true }
            .disabled(!model.snapshot.profile.on && model.journal.entries.isEmpty)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Undo")
    .confirmationDialog("Undo everything StorageDaddy changed?", isPresented: $confirming) {
      Button("Undo Everything", role: .destructive) { model.undoEverything() }
    } message: {
      Text("macOS asks you to remove the profile in System Settings. Deleted models download again when a feature needs them, and files in the Trash stay there.")
    }
  }

  func title(_ id: String) -> String {
    if let t = Tweaks.tweak(id) { return t.title }
    if let item = model.background.first(where: { $0.id == id }) { return "Background item: \(item.owner)" }
    return id
  }
}

struct Footer: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}
