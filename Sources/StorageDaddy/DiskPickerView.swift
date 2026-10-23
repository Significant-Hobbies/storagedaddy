import SwiftUI
import AppKit
import DiskCore

struct DiskPickerView: View {
    @EnvironmentObject private var m: ExplorerModel
    @Binding private var isPresented: Bool
    @State private var volumes: [StorageVolume] = []

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Scan a disk").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Choose a mounted filesystem to inspect its readable files.")
                        .foregroundStyle(Tints.secondaryText)
                }
                DoodleArt(topic: .overview).frame(width: 64, height: 64)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            Text("storagedaddy scans only the filesystem you choose. It does not promise a complete accounting of every physical disk block, and it does not change permissions automatically.")
                .font(.callout)
                .foregroundStyle(Tints.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if volumes.isEmpty {
                StorageEmptyView("No readable volumes found", systemImage: "externaldrive.badge.questionmark", description: Text("Connect a volume or choose a folder to inspect."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(volumes) { volume in
                            Button {
                                m.start(volume.url)
                                isPresented = false
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: volume.isStartup ? "internaldrive.fill" : (volume.isRemovable ? "externaldrive.fill" : "externaldrive"))
                                        .font(.title2)
                                        .foregroundStyle(volume.isStartup ? Tints.mint : Tints.electricBlue)
                                        .frame(width: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(volume.name).font(.headline)
                                        Text(volume.subtitle).font(.caption).foregroundStyle(Tints.secondaryText)
                                        Text(volume.capacityDescription).font(.caption).foregroundStyle(Tints.secondaryText).monospacedDigit()
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tints.secondaryText)
                                }
                                .padding(13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(volume.isStartup ? Tints.mint.opacity(0.10) : Tints.electricBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(volume.isStartup ? Tints.mint.opacity(0.45) : Tints.electricBlue.opacity(0.24), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                Button("Open Full Disk Access Settings", systemImage: "lock.shield") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                Spacer()
                Text("Read-only selection").font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
        .padding(24)
        .background(AppColors.canvas)
        .storageTheme(DaddyTheme.palette)
        .tint(Tints.mint)
        .buttonStyle(StorageButtonStyle())
        .onAppear { volumes = discoverVolumes() }
    }

    private func discoverVolumes() -> [StorageVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        let fileManager = FileManager.default
        let startupURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        var urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        if fileManager.fileExists(atPath: startupURL.path) {
            urls.insert(startupURL, at: 0)
        } else {
            urls.insert(URL(fileURLWithPath: "/", isDirectory: true), at: 0)
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard seen.insert(path).inserted else { return nil }
            let values = try? standardized.resourceValues(forKeys: Set(keys))
            let isStartup = path == startupURL.standardizedFileURL.path || (path == "/" && !fileManager.fileExists(atPath: startupURL.path))
            let isPseudoSystemVolume = !isStartup && (
                path == "/" || path == "/System" || path.hasPrefix("/System/") ||
                path == "/private" || path.hasPrefix("/private/") || path == "/dev" || path.hasPrefix("/dev/")
            )
            guard !isPseudoSystemVolume else { return nil }
            if values?.volumeIsLocal == false, values?.volumeIsRemovable != true { return nil }

            let name: String
            if isStartup {
                name = values?.volumeName?.isEmpty == false ? (values?.volumeName ?? "Macintosh HD") : "Macintosh HD"
            } else {
                name = values?.volumeName?.isEmpty == false ? (values?.volumeName ?? standardized.lastPathComponent) : standardized.lastPathComponent
            }
            return StorageVolume(
                url: standardized,
                name: name,
                isStartup: isStartup,
                isRemovable: values?.volumeIsRemovable == true,
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values?.volumeAvailableCapacity.map(Int64.init)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private struct StorageVolume: Identifiable {
    let url: URL
    let name: String
    let isStartup: Bool
    let isRemovable: Bool
    let totalCapacity: Int64?
    let availableCapacity: Int64?

    var id: String { url.path }
    var subtitle: String { isStartup ? "Startup data volume · readable files" : (isRemovable ? "External volume · readable files" : "Local volume · readable files") }
    var capacityDescription: String {
        var values: [String] = []
        if let totalCapacity { values.append("\(DiskFormat.bytes(totalCapacity)) total") }
        if let availableCapacity { values.append("\(DiskFormat.bytes(availableCapacity)) free") }
        return values.isEmpty ? "Capacity information unavailable" : values.joined(separator: " · ")
    }
}

struct StorageMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("storagedaddy").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(20)
            Divider().overlay(Tints.secondaryText.opacity(0.24))
            ScrollView {
                Text(displayMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
            Divider().overlay(Tints.secondaryText.opacity(0.24))
            HStack {
                Button("Copy Details", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message, forType: .string) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: message.count < 500 ? 230 : 420)
        .background(AppColors.canvas)
        .storageTheme(DaddyTheme.palette)
        .buttonStyle(StorageButtonStyle())
    }

    private var displayMessage: String {
        message.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let separator = line.range(of: ": ", options: .backwards) else { return String(line) }
            let path = String(line[..<separator.lowerBound])
            guard path.hasPrefix("/") else { return String(line) }
            return "\(StorageLabels.location(path))\n\(line[separator.upperBound...])"
        }.joined(separator: "\n")
    }
}
