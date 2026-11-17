import Foundation
import Darwin
import DiskCore

@main struct StorageBench {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "fixture" {
            let count = args.count > 2 ? Int(args[2]) ?? 10000 : 10000
            guard (1...1_000_000).contains(count) else { throw BenchError.invalidCount }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageDaddy-Fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for i in 0..<count {
                let dir = root.appendingPathComponent("Folder-\(i / 100)")
                if i % 100 == 0 { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
                try Data("Fixture payload \(i % 97)\n".utf8).write(to: dir.appendingPathComponent("file-\(i).txt"))
            }
            print(root.path); return
        }
        if args.count == 3 && ["developer-cleanup", "legacy-developer-cleanup"].contains(args[1]) {
            let root = URL(fileURLWithPath: args[2])
            let start = ContinuousClock.now
            let items: [[String: Any]]
            let skipped: Int
            if args[1] == "developer-cleanup" {
                let plan = try await DeveloperCleanupPlan.prepare(root: root)
                items = plan.items.map { ["path": $0.path, "allocatedBytes": $0.allocatedBytes, "ready": $0.keptReason == nil] }
                skipped = plan.skipped
            } else {
                let scan = try await DiskScanner.scan(root: root, progress: { _ in })
                let groups = DeveloperInsights.analyze(scan)
                let report = DeveloperReport.build(scan: scan, groups: groups)
                let ids = CleanupGuidance.quickCleanupIDs(in: scan, findings: report.findings)
                var checked: [[String: Any]] = []
                for id in ids {
                    let path = scan.url(for: id).path
                    let ready: Bool
                    do {
                        try await CleanupPreflight.validate(ids: [id], in: scan, regenerableIDs: [id])
                        ready = true
                    } catch { ready = false }
                    checked.append(["path": path, "allocatedBytes": scan.nodes[id].allocatedBytes, "ready": ready])
                }
                items = checked
                skipped = scan.skipped
            }
            let duration = start.duration(to: .now).components
            let result: [String: Any] = [
                "seconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                "skipped": skipped,
                "items": items,
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
            return
        }
        guard args.count >= 3, ["compare", "compare-live", "scan", "profile", "report", "discover-dependencies"].contains(args[1]) else { print("StorageBench fixture [count]\nStorageBench compare <fixture-folder>\nStorageBench compare-live <fixture-folder>\nStorageBench scan <folder> [--live]\nStorageBench report <folder>\nStorageBench discover-dependencies <home-folder>"); return }
        let root = URL(fileURLWithPath: args[2])
        if args[1] == "discover-dependencies" {
            let started = Date()
            let result = try await ProjectDependencyDiscovery.discover(home: root)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("\(result.paths.count) node_modules · \(result.directoriesVisited) directories · \(String(format: "%.2f", Date().timeIntervalSince(started)))s · \(usage.ru_maxrss) peak RSS bytes · complete: \(result.complete) · skipped: \(result.skippedDirectories)")
            for path in result.paths.prefix(8) { print(path) }
            return
        }
        if args[1] == "report" {
            let clock = ContinuousClock()
            let scanStart = clock.now
            let scan = try await DiskScanner.scan(root: root)
            let scanDuration = scanStart.duration(to: clock.now).components
            let scanSeconds = Double(scanDuration.seconds) + Double(scanDuration.attoseconds) / 1e18

            let classifyStart = clock.now
            let groups = DeveloperInsights.analyze(scan)
            let classifyDuration = classifyStart.duration(to: clock.now).components
            let classifySeconds = Double(classifyDuration.seconds) + Double(classifyDuration.attoseconds) / 1e18

            let reportStart = clock.now
            let report = DeveloperReport.build(scan: scan, groups: groups)
            let reportDuration = reportStart.duration(to: clock.now).components
            let reportSeconds = Double(reportDuration.seconds) + Double(reportDuration.attoseconds) / 1e18

            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let projects: [[String: Any]] = report.projects.map { project in
                [
                    "name": project.name,
                    "allocatedBytes": project.allocatedBytes,
                    "categoryBytes": Dictionary(uniqueKeysWithValues: project.categoryBytes.map { ($0.key.rawValue, $0.value) })
                ]
            }
            let findings: [[String: Any]] = report.findings.map { finding in
                [
                    "id": finding.id,
                    "tool": finding.tool,
                    "category": finding.category.rawValue,
                    "allocatedBytes": finding.allocatedBytes,
                    "projectID": finding.projectID.map { $0 as Any } ?? NSNull(),
                    "evidence": finding.evidence,
                    "consequence": finding.consequence
                ]
            }
            let result: [String: Any] = [
                "entries": scan.nodes.count,
                "scanSeconds": scanSeconds,
                "classifySeconds": classifySeconds,
                "reportSeconds": reportSeconds,
                "peakRSSBytes": usage.ru_maxrss,
                "projects": projects,
                "findings": findings
            ]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            return
        }
        if args[1] == "profile" {
            var scan = try await DiskScanner.scan(root: root)
            if args.contains("--developer-replay") { scan.rootPath = "/Users/benchmark/project/node_modules" }
            var timings: [String: [Double]] = [:]
            var expected: [String]?
            for round in 0..<6 {
                for baseline in (round % 2 == 0 ? [true, false] : [false, true]) {
                    let clock = ContinuousClock(); let start = clock.now
                    let groups = baseline ? ReferenceDeveloperInsights.analyze(scan) : DeveloperInsights.analyze(scan)
                    let elapsed = start.duration(to: clock.now).components
                    timings[baseline ? "pathReconstructionBaseline" : "inheritedClassification", default: []].append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                    let totals = groups.map { "\($0.category.rawValue)|\($0.allocatedBytes)|\($0.logicalBytes)|\($0.fileCount)" }
                    if let expected, expected != totals { throw BenchError.parityFailure }
                    expected = totals
                }
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let report: [String: Any] = ["entries": scan.nodes.count, "scanSeconds": scan.elapsed, "classificationSeconds": timings, "categoryTotalsParity": true, "developerReplay": args.contains("--developer-replay"), "peakRSSBytes": usage.ru_maxrss, "note": "Six alternating classification runs. Parity covers category allocated/logical totals and file counts on this fixture, not grouping-root presentation. Whole process RSS includes both implementations."]
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            return
        }
        if args[1] == "scan" {
            let backend = args.contains("--parallel") ? ScanBackend.parallel : .bulk
            let workerCount = args.firstIndex(of: "--workers").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 8
            let s: ScanResult
            if args.contains("--live") {
                // Deliberately no-op: this measures incremental scan bookkeeping
                // without rendering or retaining progress values.
                s = try await DiskScanner.scan(root: root, backend: backend, parallelism: workerCount, progress: { _ in })
            } else {
                s = try await DiskScanner.scan(root: root, backend: backend, parallelism: workerCount)
            }
            print("\(s.nodes.count) entries, \(s.nodes.first?.allocatedBytes ?? 0) allocated bytes, \(s.elapsed) s, \(s.skipped) skipped")
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let metrics: [String: Any] = [
                "entriesPerSecond": Double(s.nodes.count) / max(s.elapsed, 0.000001),
                "processDiskReadBytes": s.processDiskReadBytes.map { $0 as Any } ?? NSNull(),
                "peakRSSBytes": usage.ru_maxrss,
                "retainedRSSBytes": ProcessMemory.residentBytes().map { $0 as Any } ?? NSNull(),
                "nodeStrideBytes": MemoryLayout<DiskNode>.stride,
                "nodeCapacity": s.nodes.capacity
            ]
            print(String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
            return
        }
        if args[1] == "compare-live" {
            var times: [String: [Double]] = [:]
            var expected: [String: String]?
            var count = 0
            for run in 0..<6 {
                let live = run % 2 == 1
                let s: ScanResult
                if live {
                    // Keep the callback bounded by Scanner and make it a no-op
                    // so this compares scanner work rather than UI work.
                    s = try await DiskScanner.scan(root: root, progress: { _ in })
                } else {
                    s = try await DiskScanner.scan(root: root)
                }
                guard s.skipped == 0, s.errors.isEmpty else { throw BenchError.incompleteScan }
                let records = scanSignature(s)
                if let expected, expected != records { throw BenchError.parityFailure }
                expected = records
                count = s.nodes.count
                times[live ? "live" : "plain", default: []].append(s.elapsed)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let medians = Dictionary(uniqueKeysWithValues: times.map { ($0.key, median($0.value)) })
            let result: [String: Any] = [
                "entries": count,
                "parity": true,
                "seconds": times,
                "medianSeconds": medians,
                "peakRSSBytes": usage.ru_maxrss,
                "note": "Six alternating plain/live scans with full per-path metadata parity. Live progress callback is no-op; Scanner bounds callback emission. Cached fixture; process peak RSS includes scans and parity maps."
            ]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            return
        }
        var times: [String: [Double]] = [:]
        var expected: [String: String]?
        var count = 0
        for round in 0..<4 {
            let order: [ScanBackend] = round % 2 == 0 ? [.foundation, .bulk, .parallel] : [.parallel, .bulk, .foundation]
            for backend in order {
                let s = try await DiskScanner.scan(root: root, backend: backend)
                guard s.skipped == 0, s.errors.isEmpty else { throw BenchError.incompleteScan }
                let records = scanSignature(s)
                if let expected, expected != records { throw BenchError.parityFailure }
                expected = records; count = s.nodes.count
                times[backend.rawValue, default: []].append(s.elapsed)
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["entries": count, "parity": true, "seconds": times, "peakRSSBytes": usage.ru_maxrss, "note": "Four alternating runs per backend in one process. Cached fixture; process peak RSS includes both scans and parity maps. Not competitor evidence."]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }

    private static func scanSignature(_ scan: ScanResult) -> [String: String] {
        Dictionary(uniqueKeysWithValues: scan.nodes.map { node in
            (
                scan.url(for: node.id).path,
                "\(node.id)|\(node.parent ?? -1)|\(node.children)|\(node.isDirectory)|\(node.isSymlink)|\(node.logicalBytes)|\(node.allocatedBytes)|\(node.device)|\(node.inode)|\(node.modified.timeIntervalSince1970)"
            )
        })
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    enum BenchError: Error { case invalidCount, parityFailure, incompleteScan }
}
