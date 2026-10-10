import SwiftUI
import SaaSMakerUI
import Observation
import Combine

/// Keeps in-progress changes alive when the owner visits another StorageDaddy workspace.
@MainActor public final class MacToolsSession: ObservableObject {
  let model: AppModel
  public init() {
    Shell.inApp = true
    model = AppModel()
    observeActivity()
  }
  init(model: AppModel) { self.model = model; observeActivity() }
  private func observeActivity() {
    withObservationTracking {
      _ = isBusy
      _ = allowsUpdateInstallation
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.objectWillChange.send()
        self.observeActivity()
      }
    }
  }
  public func setExcludedFolders(_ paths: [String]) { model.excludedFolders = paths }
  public var allowsUpdateInstallation: Bool { !isBusy && !model.reviewing && model.pendingCount == 0 && model.run == nil }
  public var isBusy: Bool {
    if case .working? = model.run { return true }
    if case .approveProfile? = model.run { return true }
    return model.cleaning || model.backgroundBusy || model.scanning
  }
}

@MainActor public struct StorageDaddyMacToolsView: View {
  private let session: MacToolsSession
  private let accent: Color, secondaryInk: Color
  private let operationAllowed: Bool
  public init(session: MacToolsSession, accent: Color, secondaryInk: Color, operationAllowed: Bool = true) {
    self.session = session; self.accent = accent; self.secondaryInk = secondaryInk; self.operationAllowed = operationAllowed
  }
  public var body: some View {
    @Bindable var model = session.model
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        SMSectionHeader("Mac Controls", size: 28).accessibilityLabel("Mac Controls")
        Spacer()
        Button("Refresh") { model.reload(resetChoices: true) }.disabled(session.isBusy)
      }.padding(.horizontal, 24).padding(.top, 24)
      if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 { Text("Mac Controls requires macOS 26 or newer.").padding(.horizontal, 24) }
      if !operationAllowed { Text("Finish the current storage operation or cleanup review to use Mac Controls.").foregroundStyle(secondaryInk).padding(.horizontal, 24) }
      Picker("Section", selection: $model.page) {
        Text("Overview").tag(Page.overview as Page?)
        Text("Apple Intelligence").tag(Page.intelligence as Page?)
        ForEach(TweakGroup.allCases) { group in Text(group.title).tag(Page.group(group) as Page?) }
        Text("Background Items").tag(Page.background as Page?)
        Text("Storage cleanup").tag(Page.storage as Page?)
        Text("Undo").tag(Page.changes as Page?)
      }.pickerStyle(.menu).padding(.horizontal, 24).disabled(session.isBusy)
      DetailView(page: model.page ?? .overview)
        .scrollContentBackground(.hidden)
        .disabled(session.isBusy)
      if model.pendingCount > 0 { PendingBar().disabled(session.isBusy) }
      Link("RemoveMacAI by omlahore · pared by 4evy · MIT licenses", destination: URL(string: "https://github.com/omlahore/RemoveMacAI")!)
        .font(.caption).foregroundStyle(secondaryInk).padding(.horizontal, 24).padding(.bottom, 12)
    }
    .disabled(!operationAllowed || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26)
    .environment(model)
    .background(Color.black)
    .tint(accent)
    .sheet(isPresented: $model.reviewing) { ReviewSheet().environment(model) }
    .sheet(isPresented: Binding(get: { model.run != nil }, set: { if !$0 { model.dismissRun() } })) {
      RunSheet().environment(model)
    }
  }
}
