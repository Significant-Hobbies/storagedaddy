import SwiftUI
import AppKit
import DiskCore

@MainActor final class DashboardModel: ObservableObject {
    @Published var report: SystemStorageReport?
    @Published var health: [NVMeHealthInfo] = []
    @Published var loading = false
    @Published var ioRates: StorageDashboardMetrics.IORates = .waiting
    private var samplingVersion = UUID()

    func sampleWhileVisible(probe: @escaping @Sendable () -> StorageDashboardMetrics.IOSample = StorageDashboardMetrics.collectIOSample,
                            interval: Duration = .seconds(2)) async {
        let version = UUID(); samplingVersion = version
        ioRates = .waiting
        var previous: StorageDashboardMetrics.IOSample?
        defer { if samplingVersion == version { ioRates = .waiting } }
        while !Task.isCancelled, samplingVersion == version {
            let worker = Task.detached(priority: .utility, operation: probe)
            let sample = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, samplingVersion == version else { return }
            ioRates = StorageDashboardMetrics.ioRates(previous: previous, current: sample)
            previous = sample
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    static func scopedScore(_ report: SystemStorageReport) -> (String, StorageDashboardMetrics.Score) {
        let volume = report.volumes.first(where: \.isStartupData) ?? report.volumes.first(where: { $0.mountPoint == "/" })
        let validCapacity = volume.flatMap { v -> MountedVolumeInfo? in
            guard let total = v.totalCapacity, total > 0, let free = v.availableCapacity, free >= 0, free <= total else { return nil }
            return v
        }
        let purgeable = validCapacity.flatMap { v -> Int64? in
            guard let important = v.importantAvailableCapacity, let free = v.availableCapacity,
                  let total = v.totalCapacity, important >= free, important <= total else { return nil }
            return important - free
        }
        return (volume.map { $0.name + " (" + $0.mountPoint + ")" } ?? "Startup scope unavailable",
            StorageDashboardMetrics.score(totalBytes: validCapacity?.totalCapacity, freeBytes: validCapacity?.availableCapacity,
                purgeableBytes: purgeable, nvmePercentUsed: nil,
                snapshotCount: volume?.mountPoint == "/" ? report.pressure.localSnapshotNames?.count : nil))
    }

    func loadIfNeeded() {
        if report == nil { refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let report = SystemInventory.collect()
            let health = NVMeHealthReader.collect()
            await MainActor.run {
                self.report = report
                self.health = health
                self.loading = false
            }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var m: ExplorerModel
    @ObservedObject var dashboard: DashboardModel
    @State private var showingSystemDetails = false

    private var scanLeaders: [DiskNode] {
        guard let scan = m.scan, let root = scan.nodes.first else { return [] }
        return root.children.map { scan.nodes[$0] }
            .filter { $0.allocatedBytes > 0 }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let report = dashboard.report {
                        let wide = geometry.size.width >= 760
                        let layout = wide
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                        layout {
                            capacityPanel(report)
                                .frame(maxWidth: .infinity)
                            cleanupPanel(minHeight: wide ? 294 : 190)
                                .frame(width: wide ? min(340, geometry.size.width * 0.43) : nil)
                                .frame(maxWidth: wide ? nil : .infinity)
                        }
                        latestScanPanel
                        let scoped = DashboardModel.scopedScore(report)
                        StorageDashboardMetricsView(volumes: report.volumes, rates: dashboard.ioRates, score: scoped.1,
                            scoreScope: scoped.0, isRefreshing: dashboard.loading, onRefresh: dashboard.refresh,
                            onReviewSnapshots: { showingSystemDetails = true })
                        layout {
                            DashboardTrashPanel(excludedFolders: m.excludedFolders)
                                .frame(maxWidth: .infinity)
                            usefulSignals(report)
                                .frame(maxWidth: .infinity)
                        }
                        systemDetails(report)
                    } else {
                        StorageEmptyView("Reading system storage…", systemImage: "internaldrive", description: Text("Collecting capacity and device information."))
                    }
                }
                .padding(24)
                .frame(maxWidth: 1320, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.visible)
        }
        .background(Color.black)
        .buttonStyle(StorageButtonStyle())
        .task { dashboard.loadIfNeeded(); await dashboard.sampleWhileVisible() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("YOUR MAC").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(Tints.mint)
                Text("Storage dashboard").font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text("Space, the latest scan, and what is worth reviewing.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Button("Refresh", action: dashboard.refresh).disabled(dashboard.loading || m.busy)
                if let report = dashboard.report {
                    Text("Checked \(report.collectedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }
            }
            if dashboard.loading { ProgressView().controlSize(.small) }
        }
    }

    private func capacityPanel(_ report: SystemStorageReport) -> some View {
        let capacity = StartupCapacity(volumes: report.volumes)
        let startup = report.volumes.first(where: \.isStartupData)
            ?? report.volumes.first(where: { $0.mountPoint == "/" })
        return VStack(alignment: .leading, spacing: 18) {
            Label("STARTUP STORAGE", systemImage: "internaldrive.fill")
                .font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Tints.mint)
            if let capacity {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(capacity.usedPercent)%")
                        .font(.system(size: 76, weight: .semibold, design: .rounded))
                        .tracking(-4).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("used").font(.title3.weight(.semibold))
                        Text("\(DiskFormat.bytes(capacity.available)) available")
                            .font(.callout).foregroundStyle(Tints.mint).monospacedDigit()
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tints.mint.opacity(0.2))
                        Capsule().fill(Tints.mint)
                            .frame(width: max(2, geometry.size.width * capacity.usedFraction))
                    }
                }
                .frame(height: 12)
                HStack {
                    Text("\(DiskFormat.bytes(capacity.used)) used")
                    Spacer()
                    Text("\(DiskFormat.bytes(capacity.total)) total")
                }
                .font(.caption).monospacedDigit().foregroundStyle(Tints.secondaryText)
                if let purgeable = startup?.purgeableCapacity, purgeable > 0 {
                    Text("\(DiskFormat.bytes(purgeable)) purgeable · macOS may reclaim this when needed")
                        .font(.caption).foregroundStyle(Tints.cyan)
                }
                Text("Startup capacity is a macOS estimate. Scan totals below cover only the location scanned.")
                    .font(.caption2).foregroundStyle(Tints.secondaryText)
            } else {
                Text("Startup capacity unavailable")
                    .font(.title3).foregroundStyle(Tints.secondaryText)
                Text("The latest scan and cleanup review are still available below.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 294, alignment: .topLeading)
        .background(Tints.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
    }

    private func cleanupPanel(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("EASY CLEANUP", systemImage: "sparkles")
                .font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Tints.yellow)
            if let scan = m.scan {
                if m.exclusionResultsStale {
                    Text("Rescan needed").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Excluded folders changed since this scan. Refresh before reviewing candidates.")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                    Button("Rescan this location", action: m.rescan).disabled(m.busy)
                } else {
                    Text(DiskFormat.bytes(m.easyCleanupBytes))
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .tracking(-1.5).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    Text("\(m.easyCleanupIDs.count) usually regenerable \(m.easyCleanupIDs.count == 1 ? "item" : "items") in this scan")
                        .font(.callout.weight(.medium))
                    Text("Candidates only. Each item is checked before staging and nothing moves until you confirm.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                    Button("Review candidates") { m.openStorage(.cleanup) }
                        .disabled(m.busy || m.easyCleanupIDs.isEmpty)
                    if !m.staged.isEmpty {
                        Text("\(m.staged.count) already staged for review")
                            .font(.caption).foregroundStyle(Tints.yellow)
                    }
                }
                Text("From \(StorageLabels.location(scan.rootPath))")
                    .font(.caption2).foregroundStyle(Tints.secondaryText).lineLimit(1)
                    .help(scan.rootPath)
            } else {
                Text("Scan to find candidates")
                    .font(.title3.weight(.semibold))
                Text("Build outputs, dependency folders and package caches can be suggested after a scan.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                Button("Scan user caches", action: m.scanUserCaches).disabled(m.busy)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(Tints.yellow.opacity(0.11), in: RoundedRectangle(cornerRadius: 17))
    }

    private var latestScanPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latest scan").font(.title3.weight(.semibold))
                Spacer()
                if m.scan != nil { Button("Open Explore") { m.openStorage(.explore) }.font(.callout) }
            }
            if let scan = m.scan, let root = scan.nodes.first {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(DiskFormat.bytes(root.allocatedBytes))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("on disk in \(StorageLabels.location(scan.rootPath))")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                        .lineLimit(2).help(scan.rootPath)
                    Spacer(minLength: 0)
                }
                scanComposition(root: root)
                HStack(spacing: 18) {
                    ForEach(Array(scanLeaders.prefix(3).enumerated()), id: \.element.id) { index, node in
                        Button {
                            m.openStorage(.explore)
                            m.selected = node.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Tints.colors[index % Tints.colors.count]).frame(width: 8, height: 8)
                                Text("\(StorageLabels.name(node)) · \(DiskFormat.bytes(node.allocatedBytes))")
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain).font(.caption)
                        .help(scan.url(for: node.id).path)
                    }
                }
            } else {
                Text("No scan yet. Scan a folder to see what takes space and which items may be reviewed for cleanup.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().overlay(Tints.secondaryText.opacity(0.18)) }
    }

    private func scanComposition(root: DiskNode) -> some View {
        let leaders = Array(scanLeaders.prefix(3))
        return GeometryReader { geometry in
            Canvas { context, size in
                let total = Double(max(1, root.allocatedBytes))
                var offset = 0.0
                for (index, node) in leaders.enumerated() {
                    let width = min(size.width - offset, size.width * Double(node.allocatedBytes) / total)
                    guard width > 0 else { continue }
                    context.fill(Path(CGRect(x: offset, y: 0, width: width, height: size.height)),
                                 with: .color(Tints.colors[index % Tints.colors.count]))
                    offset += width
                }
                if offset < size.width {
                    context.fill(Path(CGRect(x: offset, y: 0, width: size.width - offset, height: size.height)),
                                 with: .color(Tints.secondaryText.opacity(0.18)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .frame(height: 18)
        .accessibilityLabel("Largest three items occupy \(leaders.map { StorageLabels.name($0) }.joined(separator: ", ")) of this scan")
    }

    private func usefulSignals(_ report: SystemStorageReport) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Coverage & signals").font(.title3.weight(.semibold))
            if let scan = m.scan, scan.skipped > 0 {
                Label("\(scan.skipped.formatted()) items skipped by the latest scan", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Tints.yellow)
                Text("The scan total is partial. Open Explore for the scanned items and coverage details.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            if let snapshots = report.pressure.localSnapshotNames, !snapshots.isEmpty {
                Label("\(snapshots.count) local APFS \(snapshots.count == 1 ? "snapshot" : "snapshots")", systemImage: "camera.aperture")
                    .font(.callout)
            }
            if let used = report.pressure.swapUsedBytes, used > 0 {
                Label("\(DiskFormat.bytes(Int64(clamping: used))) swap in use", systemImage: "arrow.triangle.swap")
                    .font(.callout)
            }
            if m.scan?.skipped == 0,
               (report.pressure.localSnapshotNames?.isEmpty ?? true),
               (report.pressure.swapUsedBytes ?? 0) == 0 {
                Text("No active swap or local snapshots reported.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
            } else if m.scan == nil,
                      (report.pressure.localSnapshotNames?.isEmpty ?? true),
                      (report.pressure.swapUsedBytes ?? 0) == 0 {
                Text("Scan coverage appears here after a scan.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
            }
            Button("Drive and volume details") { showingSystemDetails = true }
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func systemDetails(_ report: SystemStorageReport) -> some View {
        DisclosureGroup(isExpanded: $showingSystemDetails) {
            VStack(alignment: .leading, spacing: 22) {
                otherContainersSection(report)
                volumesSection(report.volumes)
                healthSection
                pressureSection(report.pressure)
            }
            .padding(.top, 16)
        } label: {
            HStack {
                Label("System details", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                Text("APFS pools · mounted volumes · drive health · pressure")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
        .padding(20)
        .background(Tints.secondaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func otherContainersSection(_ report: SystemStorageReport) -> some View {
        let startupContainer = report.volumes.first(where: \.isStartupData)?.apfsContainer
        let others = report.containers.filter { $0.name != startupContainer }
        return VStack(alignment: .leading, spacing: 9) {
            Text("OTHER APFS POOLS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Tints.secondaryText)
            if others.isEmpty {
                Text("No other APFS pools found.").font(.caption).foregroundStyle(Tints.secondaryText)
            }
            ForEach(others) { container in
                HStack(spacing: 12) {
                    Text(container.volumeNames.first ?? container.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(container.name).font(.caption2).foregroundStyle(Tints.secondaryText)
                    Spacer(minLength: 8)
                    if let total = container.totalCapacity, let free = container.freeCapacity {
                        Text("\(DiskFormat.bytes(max(0, total - free))) used · \(DiskFormat.bytes(free)) free")
                            .font(.caption).monospacedDigit().foregroundStyle(Tints.secondaryText)
                    } else {
                        Text("Capacity unavailable").font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    // MARK: - Volumes

    private func volumesSection(_ volumes: [MountedVolumeInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOUNTED VOLUMES").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Tints.secondaryText)
            ForEach(volumes, id: \.mountPoint) { volume in
                HStack(spacing: 12) {
                    Image(systemName: volumeIcon(volume))
                        .foregroundStyle(volume.isSystem ? Tints.secondaryText : Tints.electricBlue)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(volume.name).font(.callout.weight(.medium))
                            Text(volume.fsDisplayName).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Tints.secondaryText.opacity(0.12), in: Capsule())
                            ForEach(volumeBadges(volume), id: \.self) { badge in
                                Text(badge).font(.caption2).foregroundStyle(Tints.yellow)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Tints.yellow.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(StorageLabels.location(volume.mountPoint))
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                            .lineLimit(1).truncationMode(.middle).help(volume.mountPoint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let total = volume.totalCapacity, let free = volume.availableCapacity {
                            Text("\(DiskFormat.bytes(free)) free of \(DiskFormat.bytes(total))")
                                .font(.callout).monospacedDigit()
                            if let purgeable = volume.purgeableCapacity, purgeable > 0 {
                                Text("\(DiskFormat.bytes(purgeable)) purgeable")
                                    .font(.caption2).foregroundStyle(Tints.cyan)
                                    .help("Space macOS can reclaim on demand — local snapshots, caches and cloud-only copies. Counted as used, not as free.")
                            }
                        } else {
                            Text("Capacity unavailable").font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(Tints.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func volumeIcon(_ volume: MountedVolumeInfo) -> String {
        if volume.isStartupData { return "internaldrive.fill" }
        if volume.isNetwork { return "network" }
        if volume.isDiskImage { return "doc.zipper" }
        if volume.isSystem { return "gearshape.2" }
        return volume.isRemovable || !volume.isInternal ? "externaldrive.fill" : "internaldrive"
    }

    private func volumeBadges(_ volume: MountedVolumeInfo) -> [String] {
        var badges: [String] = []
        if volume.isEncrypted == true { badges.append("Encrypted") }
        if volume.isReadOnly { badges.append("Read-only") }
        if volume.isDiskImage { badges.append("Disk image") }
        if volume.isSystem { badges.append("System") }
        return badges
    }

    // MARK: - Drive health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DRIVES").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Tints.secondaryText)
            let physical = dashboard.report?.devices.filter { !$0.isDiskImage } ?? []
            ForEach(Array(physical.enumerated()), id: \.offset) { _, device in
                let health = dashboard.health.first { $0.deviceName == device.productName }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "memorychip").foregroundStyle(Tints.mint).frame(width: 22)
                        Text(device.productName).font(.callout.weight(.medium))
                        if device.isSolidState {
                            Text("SSD").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Tints.mint.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        if let health {
                            Text(health.statusLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(health.isHealthy ? Tints.mint : Tints.coral)
                        } else {
                            Text(device.smartCapable ? "SMART read unavailable" : "No SMART interface")
                                .font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                    }
                    if let health {
                        Divider().overlay(Tints.secondaryText.opacity(0.15))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                            healthMetric("Wear used", "\(health.percentUsed)%", help: "The drive's own endurance estimate. 100% means the rated write endurance is consumed; warranty guidance, not a failure prediction.")
                            healthMetric("Spare blocks", "\(health.availableSparePercent)%", help: "Reserve flash remaining for remapping worn cells. The drive warns at \(health.availableSpareThreshold)%.")
                            if let temp = health.temperatureCelsius {
                                healthMetric("Temperature", String(format: "%.0f °C", temp))
                            }
                            if let written = health.dataWrittenBytes {
                                healthMetric("Lifetime written", DiskFormat.bytes(Int64(clamping: written)))
                            }
                            if let read = health.dataReadBytes {
                                healthMetric("Lifetime read", DiskFormat.bytes(Int64(clamping: read)))
                            }
                            healthMetric("Power on", "\(health.powerOnHours.formatted()) h")
                            healthMetric("Unsafe shutdowns", health.unsafeShutdowns.formatted(), help: "Power losses without a clean flush. High counts can age the drive.")
                            healthMetric("Media errors", health.mediaErrors.formatted())
                        }
                        ForEach(health.warningDescriptions, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tints.coral)
                        }
                    }
                }
                .padding(12)
                .background(Tints.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            if physical.isEmpty {
                Text("No physical storage devices were found in the I/O registry.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
        }
    }

    private func healthMetric(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(Tints.secondaryText)
        }
        .ifHelp(help)
    }

    // MARK: - Pressure

    private func pressureSection(_ pressure: PressureInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESSURE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Tints.secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                if let total = pressure.swapTotalBytes {
                    HStack {
                        Label("Swap", systemImage: "arrow.triangle.swap").foregroundStyle(Tints.electricBlue)
                        Spacer()
                        Text(pressure.swapIsActive
                             ? "\(DiskFormat.bytes(Int64(clamping: pressure.swapUsedBytes ?? 0))) used of \(DiskFormat.bytes(Int64(clamping: total)))"
                             : "Not in use · \(DiskFormat.bytes(Int64(clamping: total))) reserved")
                            .font(.callout).monospacedDigit()
                    }
                    Text("Swap writes reach the SSD; sustained swap use adds wear.")
                        .font(.caption2).foregroundStyle(Tints.secondaryText)
                }
                if let headroom = pressure.memoryHeadroomPercent {
                    HStack {
                        Label("Memory headroom", systemImage: "memorychip").foregroundStyle(Tints.cyan)
                        Spacer()
                        Text("\(headroom)%").font(.callout).monospacedDigit()
                    }
                    Text("Kernel estimate of remaining memory capacity (kern.memorystatus_level). Higher means more headroom.")
                        .font(.caption2).foregroundStyle(Tints.secondaryText)
                }
                if let snapshots = pressure.localSnapshotNames {
                    HStack {
                        Label("Local snapshots", systemImage: "camera.aperture").foregroundStyle(Tints.yellow)
                        Spacer()
                        Text("\(snapshots.count)").font(.callout).monospacedDigit()
                    }
                    Text("APFS snapshots share blocks with live data and count as purgeable space, not as free.")
                        .font(.caption2).foregroundStyle(Tints.secondaryText)
                }
                if let read = pressure.ioReadBytesSinceBoot, let written = pressure.ioWriteBytesSinceBoot {
                    HStack {
                        Label("Disk I/O since boot", systemImage: "arrow.up.arrow.down").foregroundStyle(Tints.secondaryText)
                        Spacer()
                        Text("\(DiskFormat.bytes(Int64(clamping: read))) read · \(DiskFormat.bytes(Int64(clamping: written))) written")
                            .font(.callout).monospacedDigit()
                    }
                }
                if let boot = pressure.bootTime {
                    HStack {
                        Label("Booted", systemImage: "power").foregroundStyle(Tints.secondaryText)
                        Spacer()
                        Text(boot.formatted(.relative(presentation: .named))).font(.callout)
                    }
                }
            }
            .padding(12)
            .background(Tints.secondaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct DashboardTrashPanel: View {
    let excludedFolders: [String]
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var inventory = TrashInventoryModel()
    @State private var hasFullDiskAccess = false
    private let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("In Trash", systemImage: "trash").font(.title3.weight(.semibold))
                Spacer()
                if inventory.loading { ProgressView().controlSize(.small) }
                if inventory.scan != nil {
                    Button("Refresh") { inventory.refresh(excludedFolders: excludedFolders) }
                        .font(.caption).disabled(inventory.loading)
                }
            }
            if let scan = inventory.scan {
                Text("\(DiskFormat.bytes(inventory.allocatedBytes)) in \(inventory.items.count.formatted()) Home Trash \(inventory.items.count == 1 ? "item" : "items")")
                    .font(.callout.weight(.medium)).monospacedDigit()
                ForEach(Array(inventory.items.prefix(3))) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(Tints.mint)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(DiskFormat.bytes(item.allocatedBytes))
                            .monospacedDigit().foregroundStyle(Tints.secondaryText)
                    }
                    .font(.caption)
                    .help(scan.url(for: item.id).path)
                }
                if inventory.items.count > 3 {
                    Text("+ \(inventory.items.count - 3) more items")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }
                if scan.skipped > 0 {
                    Text("\(scan.skipped.formatted()) items skipped; measured size is partial.")
                        .font(.caption).foregroundStyle(Tints.yellow)
                }
            } else if let error = inventory.error {
                Text(error).font(.caption).foregroundStyle(Tints.yellow)
            } else if !hasFullDiskAccess {
                Text("Review the items in Finder. Listing Home Trash here needs Full Disk Access; this dashboard will not ask for it.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            } else if inventory.loading {
                Text("Reading Home Trash item names and sizes…")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            Button("Open Trash in Finder") { NSWorkspace.shared.open(trash) }
                .font(.callout)
            Text("Current user's Home Trash only. Nothing is emptied here.")
                .font(.caption2).foregroundStyle(Tints.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: updateAccess)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updateAccess() }
        }
        .onDisappear { inventory.cancel() }
    }

    private func updateAccess() {
        hasFullDiskAccess = FullDiskAccessProbe.status() == .accessible
        if hasFullDiskAccess && inventory.scan == nil && !inventory.loading {
            inventory.refresh(excludedFolders: excludedFolders)
        }
    }
}

private extension View {
    @ViewBuilder func ifHelp(_ text: String?) -> some View {
        if let text { self.help(text) } else { self }
    }
}

extension APFSContainerInfo: Identifiable { public var id: String { name } }
