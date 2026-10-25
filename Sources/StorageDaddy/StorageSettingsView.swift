import AppKit
import SwiftUI
import DiskCore

struct StorageSettingsView: View {
    @EnvironmentObject private var model: ExplorerModel
    @ObservedObject var updates: AppUpdates
    @State private var tab = 1
    @AppStorage("automaticallySaveScans") private var automaticallySaveScans = true
    @AppStorage("appearanceMode") private var appearance = "dark"
    @AppStorage("colorBlindMap") private var colorBlindMap = false
    @AppStorage("binaryStorageUnits") private var binaryStorageUnits = false

    @AppStorage("scanWorkerCount") private var scanWorkerCount = 0
    @AppStorage("startMinimized") private var startMinimized = false

    var body: some View {
        TabView(selection: $tab) {
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text("General").font(.title2.weight(.semibold))
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system"); Text("Dark").tag("dark"); Text("Light").tag("light")
                }
                Picker("Scan power", selection: $scanWorkerCount) {
                    Text("Automatic").tag(0); Text("Efficient · 1 worker").tag(1); Text("Balanced · 4 workers").tag(4); Text("Fast · 8 workers").tag(8)
                }.disabled(model.busy)
                Toggle("Start minimized in the menu bar", isOn: $startMinimized)
                Toggle("Color-blind map palette", isOn: $colorBlindMap)
                Toggle("Binary storage units (KiB, MiB, GiB)", isOn: $binaryStorageUnits)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Yours free forever, including all future versions.").font(.headline).foregroundStyle(Tints.mint)
                    Text("Everyone who downloads during early access gets every future version free. No trial expiry or subscription.")
                        .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecks)
                Toggle("Save completed scans to local history", isOn: $automaticallySaveScans)
                Text("Keeps file paths, sizes and modification dates for comparisons. File contents stay out of history.").font(.caption).foregroundStyle(Tints.secondaryText)
                Text("storagedaddy checks for new versions. Installation waits until scans, exports and cleanup review are finished.")
                    .foregroundStyle(Tints.secondaryText)
                Button("Check for Updates…", action: updates.check)
                    .disabled(!updates.canCheck || !updates.isIdle)
                Spacer()
            }.padding(28) }
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Excluded Folders").font(.title2.weight(.semibold))
                    Text("Leave these folders out of future disk scans and storage cleanup. A parent folder containing an exclusion is also protected from cleanup.")
                        .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                if model.excludedFolders.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.minus").font(.system(size: 28)).foregroundStyle(Tints.mint)
                        Text("No folders excluded").font(.headline)
                        Text("Add folders you want storagedaddy to leave alone.")
                            .foregroundStyle(Tints.secondaryText)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.excludedFolders, id: \.self) { path in
                                HStack(alignment: .center, spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundStyle(Tints.mint)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: path).lastPathComponent)
                                            .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                        Text(StorageLabels.location(path)).font(.caption)
                                            .foregroundStyle(Tints.secondaryText).lineLimit(2).truncationMode(.middle)
                                    }.help(path).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Button("Remove") { model.removeExcludedFolder(path) }
                                        .accessibilityLabel("Remove exclusion for \(path)")
                                        .disabled(model.busy)
                                }.padding(.vertical, 12)
                                Divider().overlay(Tints.mint.opacity(0.2))
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus", action: chooseFolders)
                        .buttonStyle(StorageButtonStyle(prominent: true)).disabled(model.busy)
                    Spacer()
                    Text("\(model.excludedFolders.count) excluded").foregroundStyle(Tints.secondaryText)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if model.busy {
                        Text("Wait for the current operation to finish before changing exclusions.")
                    } else if model.exclusionResultsStale {
                        HStack {
                            Text("Exclusions changed. Rescan to update existing results.")
                            Spacer()
                            Button("Rescan", action: model.rescan)
                        }
                    }
                    Text("Saved automatically on this Mac. Changing exclusions clears the cleanup queue. Applications and AI tools use their own inventories; these rules apply to disk scans and storage cleanup.")
                }.font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            }.padding(28)
                .tabItem { Label("Excluded Folders", systemImage: "folder.badge.minus") }.tag(1)

            AcknowledgmentsView()
                .tabItem { Label("Acknowledgments", systemImage: "heart.text.square") }.tag(2)
            ScanScheduleSettingsView(schedule: model.scanSchedule)
                .tabItem { Label("Recurring Scans", systemImage: "clock.arrow.circlepath") }.tag(3)
        }
        .frame(width: 620, height: 520)
        .background(AppColors.canvas)
        .storageTheme(DaddyTheme.palette)
        .tint(Tints.mint)
        .buttonStyle(StorageButtonStyle())
    }

    private func chooseFolders() {
        guard !model.busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Exclude Folders"
        panel.prompt = "Exclude"
        panel.message = "These folders and their contents will be skipped by disk scans and protected from storage cleanup."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK { model.addExcludedFolders(panel.urls) }
    }
}
