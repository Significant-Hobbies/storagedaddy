import DiskCore
import SwiftUI
import AppKit
import Darwin

enum DoodleTopic: Int {
    case overview, explore, applications, duplicates, snapshots, monitor, cleanup, thanks, agents
}

/// One cached sprite sheet supplies all decorative page artwork.
struct DoodleArt: View {
    let topic: DoodleTopic
    private static let image = Bundle.main.url(forResource: "PageDoodles", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        GeometryReader { g in
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: g.size.width * 3, height: g.size.height * 3)
                    .offset(x: -CGFloat(topic.rawValue % 3) * g.size.width,
                            y: -CGFloat(topic.rawValue / 3) * g.size.height)
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WelcomeIllustration: View {
    private static let image = Bundle.main.url(forResource: "Welcome", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        if let image = Self.image { Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true) }
    }
}

struct ScanWelcomeView: View {
    let scanDisk: () -> Void
    let scanFolder: () -> Void
    let scanHome: () -> Void
    let scanCaches: () -> Void
    var later: (() -> Void)? = nil
    @State private var accessDetails = false
    @State private var accessStatus: FullDiskAccessStatus = .unknown
    @State private var startupCapacity: StartupCapacity?
    @State private var capacityLoaded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label("Welcome to storagedaddy", systemImage: "sparkle")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Tints.mint)
                    Spacer()
                    if let later { Button("Explore tools first", action: later).font(.caption) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        introduction.frame(width: 330, alignment: .leading)
                        WelcomeIllustration().frame(width: 260, height: 190)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        WelcomeIllustration().frame(width: 220, height: 135)
                        introduction
                    }
                }
                Text("Find bulky builds, forgotten caches, installed modules and AI sessions. Your results appear as the scan runs.")
                    .font(.system(size: 15)).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                capacitySummary
                HStack(spacing: 12) {
                    Button("Scan a Disk…", systemImage: "internaldrive.fill", action: scanDisk)
                        .buttonStyle(StorageButtonStyle(prominent: true)).controlSize(.large)
                    Button("Scan Home Folder", systemImage: "house", action: scanHome).controlSize(.large)
                    Button("Scan a Folder…", systemImage: "folder.badge.plus", action: scanFolder)
                        .controlSize(.large)
                }
                Text("Scan Home Folder finds caches and node_modules in readable locations. Without Full Disk Access, protected folders are skipped to avoid macOS prompts; choose one with Scan a Folder if you want it included. Scan a Disk covers the rest of that volume.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
                Button("Scan only user caches (faster)", systemImage: "archivebox", action: scanCaches)
                    .font(.callout)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield").foregroundStyle(Tints.mint).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(accessStatusTitle).font(.headline)
                        Text(accessStatusDescription)
                            .font(.callout).foregroundStyle(Tints.secondaryText)
                        if accessStatus != .accessible {
                            HStack(spacing: 12) {
                                Button("Access options") { accessDetails.toggle() }
                                Text("Or scan just one folder").font(.caption).foregroundStyle(Tints.secondaryText)
                            }
                        }
                        Text(accessCoverageNote)
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                        if accessDetails && accessStatus != .accessible {
                            Text("Open Privacy & Security → Full Disk Access, add storagedaddy with + and enable it. Reopen the app if macOS asks. This grants broad access to your files; protected and excluded items can still be skipped.")
                                .font(.callout).foregroundStyle(Tints.secondaryText)
                            HStack {
                                Button("Open System Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                                }
                                Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            }
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Tints.mint.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.2)))
                HStack(alignment: .top, spacing: 20) {
                    step(.overview, "1. Scan", "Choose your storage")
                    step(.explore, "2. Explore", "See what takes space")
                    step(.cleanup, "3. Review", "You decide what goes")
                }
                .padding(.top, 2)
                Text("On your Mac. No uploads. Nothing deleted by a scan.")
                    .font(.system(size: 13)).foregroundStyle(Tints.mint)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.black).buttonStyle(StorageButtonStyle())
        .onAppear { accessStatus = FullDiskAccessProbe.status() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accessStatus = FullDiskAccessProbe.status() }
        }
        .task {
            let volumes = await Task.detached(priority: .utility) { SystemInventory.mountedVolumes() }.value
            guard !Task.isCancelled else { return }
            startupCapacity = StartupCapacity(volumes: volumes)
            capacityLoaded = true
        }
    }

    private var capacitySummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("STARTUP STORAGE").font(.system(size: 11, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(Tints.secondaryText)
                Spacer()
                Text("macOS estimate").font(.caption).foregroundStyle(Tints.secondaryText)
            }
            if let capacity = startupCapacity {
                HStack(alignment: .top, spacing: 16) {
                    capacityMetric("Capacity", DiskFormat.bytes(capacity.total), color: .white)
                    capacityMetric("Used", DiskFormat.bytes(capacity.used), color: Tints.mint)
                    capacityMetric("Available", DiskFormat.bytes(capacity.available), color: Tints.electricBlue)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5).fill(Tints.electricBlue.opacity(0.25))
                        RoundedRectangle(cornerRadius: 5).fill(Tints.mint)
                            .frame(width: geometry.size.width * capacity.usedFraction)
                    }
                }
                .frame(height: 10)
                .accessibilityLabel("\(capacity.usedPercent) percent used, \(capacity.availablePercent) percent available")
                HStack {
                    Text("\(capacity.usedPercent)% used").foregroundStyle(Tints.mint)
                    Spacer()
                    Text("\(capacity.availablePercent)% available").foregroundStyle(Tints.electricBlue)
                }
                .font(.caption.monospacedDigit())
            } else if capacityLoaded {
                Text("Capacity unavailable. You can still scan a disk or folder.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
            } else {
                ProgressView("Reading startup storage…").controlSize(.small)
            }
            Text("Used space can include purgeable data. These are disk capacity figures, not scanned file totals.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .padding(16)
        .background(Tints.mint.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.2)))
    }

    private func capacityMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(color).minimumScaleFactor(0.75).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(Tints.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var accessStatusTitle: String {
        switch accessStatus {
        case .accessible: "Ready to scan"
        case .limited: "Protected-folder access is limited"
        case .unknown: "Protected-folder access is unknown"
        }
    }

    private var accessStatusDescription: String {
        switch accessStatus {
        case .accessible:
            "Protected-folder access is available. Choose a scan option above."
        case .limited:
            "Automatic scans skip macOS-protected folders. Choose a specific folder to include it."
        case .unknown:
            "Protected-folder access could not be confirmed. Automatic scans skip those folders to avoid prompts."
        }
    }

    private var accessCoverageNote: String {
        switch accessStatus {
        case .accessible:
            "Some protected or excluded items can still be skipped by macOS."
        case .limited, .unknown:
            "Full Disk Access is optional. A folder you choose may still need macOS approval; automatic scans avoid those prompts."
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("See what’s taking space.\nStart with a scan.")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func step(_ topic: DoodleTopic, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            DoodleArt(topic: topic).frame(width: 62, height: 62)
            Text(title).font(.headline)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Tints.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StartupCapacity: Sendable {
    let total: Int64
    let available: Int64

    init?(total: Int64, available: Int64) {
        guard total > 0, (0...total).contains(available) else { return nil }
        self.total = total
        self.available = available
    }

    init?(volumes: [MountedVolumeInfo]) {
        guard let volume = volumes.first(where: \.isStartupData)
                ?? volumes.first(where: { $0.mountPoint == "/" }),
              let total = volume.totalCapacity, total > 0,
              let available = volume.availableCapacity, (0...total).contains(available) else { return nil }
        self.total = total
        self.available = available
    }

    var used: Int64 { total - available }
    var usedFraction: Double { Double(used) / Double(total) }
    var usedPercent: Int { Int((usedFraction * 100).rounded()) }
    var availablePercent: Int { 100 - usedPercent }
}
