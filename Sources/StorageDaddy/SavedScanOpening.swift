import DiskCore
import Foundation

extension ExplorerModel {
    func openSavedScan(_ snapshot: SavedScanSnapshot) {
        guard !busy, !moves.busy, !snapshotBusy, staged.isEmpty, macTools?.isBusy != true else { return }
        busy = true
        let directory = snapshotDirectory
        savedScanTask = Task {
            defer { busy = false; savedScanTask = nil }
            do {
                let worker = Task.detached(priority: .utility) {
                    let scan = try ScanTreeArchive.read(snapshot: snapshot, directory: directory)
                    let groups = try DeveloperInsights.analyze(scan, cancellationCheck: { try Task.checkCancellation() })
                    let report = try DeveloperReport.build(scan: scan, groups: groups, cancellationCheck: { try Task.checkCancellation() })
                    let map = try StorageMapIndex(scan: scan, groups: groups, cancellationCheck: { try Task.checkCancellation() })
                    let allocation = try StorageAllocationIndex(scan: scan, cancellationCheck: { try Task.checkCancellation() })
                    let quick = CleanupGuidance.quickCleanupIDs(in: scan, findings: report.findings)
                    return (scan, groups, report, map, allocation, quick)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                scan = result.0; developerGroups = result.1; developerReport = result.2
                reportFindingsByID = Dictionary(uniqueKeysWithValues: result.2.findings.map { ($0.id, $0) })
                reportProjectNames = Dictionary(uniqueKeysWithValues: result.2.projects.map { ($0.id, $0.name) })
                mapIndex = result.3; allocationIndex = result.4; quickCleanupCandidateIDs = result.5
                fileCount = result.0.fileCount; scanStorageAccounting = nil; volumeFree = nil; volumeCapacity = nil
                previousDeveloperGroups = nil; previousDeveloperDate = nil; projectGrowth = [:]
                quickWinNodes = []; appNodes = result.0.nodes.filter { $0.isDirectory && $0.name.hasSuffix(".app") }
                scanPeakRSS = nil; lastSavedSnapshotStarted = result.0.started
                selected = nil; focus = 0; openStorage(.explore)
                progress = "Saved scan from \(result.0.started.formatted()) · Rescan for current files and sizes"
            } catch is CancellationError { progress = "Opening saved scan cancelled" }
            catch { message = error.localizedDescription }
        }
    }
}
