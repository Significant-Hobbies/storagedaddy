import Darwin
import Foundation

/// The full tree is a streamed metadata sidecar, separate from the compact
/// history listing and file-diff index. It never stores file contents.
public enum ScanTreeArchive {
    private struct Record: Codable { var header: ScanResult?; var node: DiskNode?; var allocation: FileAllocationDetail?; var allocationRecorded: Bool?; var expectedNodes: Int?; var expectedAllocations: Int? }
    public static func url(id: UUID, directory: URL) -> URL { directory.appendingPathComponent(".\(id.uuidString).tree") }

    public static func write(scan: ScanResult, id: UUID, directory: URL, byteBudget: Int64) throws {
        let target = url(id: id, directory: directory)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tree-tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Could not create the saved scan tree.") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        var total: Int64 = 0
        let encoder = JSONEncoder()
        func append(_ record: Record) throws {
            try Task.checkCancellation()
            var data = try encoder.encode(record); data.append(10)
            total += Int64(data.count)
            guard total <= min(512 * 1024 * 1024, byteBudget), data.count <= 1_048_576 else { throw failure("Saved scan tree exceeds the history storage limit.") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure("Could not finish the saved scan tree.") }
                    offset += count
                }
            }
        }
        var header = scan; header.nodes = []; header.fileAllocationDetails = nil
        guard scan.nodes.count <= 2_000_000 else { throw failure("Saved scan tree exceeds its two-million-entry limit.") }
        try append(Record(header: header, allocationRecorded: scan.fileAllocationDetails != nil, expectedNodes: scan.nodes.count, expectedAllocations: scan.fileAllocationDetails?.count ?? 0))
        for original in scan.nodes {
            var node = original; node.children = []
            try append(Record(node: node))
        }
        for allocation in scan.fileAllocationDetails ?? [] { try append(Record(allocation: allocation)) }
        guard fsync(fd) == 0, link(temporary.path, target.path) == 0 else { throw failure("Could not publish the saved scan tree.") }
    }

    public static func read(snapshot: SavedScanSnapshot, directory: URL) throws -> ScanResult {
        guard snapshot.fullTreeVersion == 1 else { throw failure("This older snapshot contains a summary only. Run a new scan to save its full tree.") }
        let fd = open(url(id: snapshot.id, directory: directory).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("The saved scan tree is unavailable.") }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_size >= 0, initial.st_size <= 512 * 1024 * 1024 else { throw failure("Invalid saved scan tree.") }
        var header: ScanResult?, nodes: [DiskNode] = [], allocations: [FileAllocationDetail] = []
        var allocationRecorded = false
        var expectedNodes = 0, expectedAllocations = 0
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 65_536), total: Int64 = 0
        let decoder = JSONDecoder()
        while true {
            try Task.checkCancellation()
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw failure("Could not read the saved scan tree.") }
            if size == 0 { break }
            total += Int64(size)
            guard total <= 512 * 1024 * 1024 else { throw failure("Saved scan tree grew beyond its read limit.") }
            pending.append(contentsOf: buffer.prefix(size))
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                guard line.count <= 1_048_576 else { throw failure("Oversized saved scan record.") }
                let record = try decoder.decode(Record.self, from: line)
                if header == nil {
                    guard let value = record.header, value.nodes.isEmpty, record.node == nil, record.allocation == nil else { throw failure("Invalid saved scan header.") }
                    guard let nodeCount = record.expectedNodes, (1...2_000_000).contains(nodeCount),
                          let allocationCount = record.expectedAllocations, (0...nodeCount).contains(allocationCount) else { throw failure("Invalid saved scan record counts.") }
                    expectedNodes = nodeCount; expectedAllocations = allocationCount
                    header = value
                    allocationRecorded = record.allocationRecorded == true
                } else if var node = record.node {
                    guard record.header == nil, record.allocation == nil, node.id == nodes.count, nodes.count < expectedNodes, node.children.isEmpty,
                          node.id == 0 ? node.parent == nil : (node.parent.map { $0 >= 0 && $0 < nodes.count && nodes[$0].isDirectory && !nodes[$0].isSymlink } ?? false) else { throw failure("Invalid saved scan hierarchy.") }
                    node.children = []
                    if let parent = node.parent { nodes[parent].children.append(node.id) }
                    nodes.append(node)
                } else if let allocation = record.allocation {
                    guard record.header == nil, allocations.count < expectedAllocations else { throw failure("Invalid saved allocation metadata.") }
                    allocations.append(allocation)
                } else { throw failure("Invalid saved scan record.") }
                pending.removeSubrange(...newline)
            }
            guard pending.count <= 1_048_576 else { throw failure("Oversized saved scan record.") }
        }
        var final = stat()
        guard fstat(fd, &final) == 0, final.st_size == initial.st_size, final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec, pending.isEmpty, nodes.count == expectedNodes, allocations.count == expectedAllocations, var result = header,
              result.rootPath == snapshot.scan.rootPath, result.started == snapshot.scan.started else { throw failure("The saved scan tree changed or does not match its snapshot.") }
        result.nodes = nodes; result.fileAllocationDetails = allocationRecorded ? allocations : nil
        try SnapshotArchive.validate(result, maximumNodes: 2_000_000)
        return result
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "ScanTreeArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
