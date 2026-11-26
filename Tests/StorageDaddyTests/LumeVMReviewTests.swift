import Foundation
import Testing
import DiskCore
@testable import StorageDaddy

struct LumeVMReviewTests {
    @Test(.enabled(if: PackageCacheTool.lume.executable() != nil))
    func installedLumeDeletesOnlyADisposableGuest() throws {
        let fm = FileManager.default
        let real = try #require(PackageCacheTool.lume.executable())
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent(".lume")
        let vm = root.appendingPathComponent("storagedaddy-fixture")
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: vm, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let disk = vm.appendingPathComponent("disk.img")
        try Data(repeating: 1, count: 65536).write(to: disk)
        try Data(repeating: 2, count: 8192).write(to: vm.appendingPathComponent("nvram.bin"))
        try Data(#"{"os":"linux","cpuCount":1,"memorySize":1073741824,"diskSize":65536,"display":"1024x768","macAddress":"02:00:00:00:00:11"}"#.utf8)
            .write(to: vm.appendingPathComponent("config.json"))
        try Data(("sha256:" + String(repeating: "a", count: 64)).utf8).write(to: vm.appendingPathComponent(".manifest-digest"))
        let sibling = root.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: sibling)
        let wrapper = bin.appendingPathComponent("lume")
        let manager = bin.appendingPathComponent("real-manager")
        try fm.createSymbolicLink(at: manager, withDestinationURL: real)
        try Data("""
        #!/bin/sh
        export HOME="$PWD" CFFIXED_USER_HOME="$PWD" LUME_HOME="$PWD/.lume"
        exec "$PWD/.local/bin/real-manager" "$@"
        """.utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let vmRow = try #require(LumeVMReview.discover(home: home, exclusions: []).first { $0.name == "storagedaddy-fixture" })
        try vmRow.remove(exclusions: [])
        #expect(!fm.fileExists(atPath: vm.path))
        #expect(fm.fileExists(atPath: sibling.path))
        #expect(try LumeVMReview.discover(home: home, exclusions: []).isEmpty)
    }

    @Test func stoppedVMRequiresFreshStateAndIdentityAndCanOnlyRemoveItsOwnDirectory() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent(".lume")
        let vm = root.appendingPathComponent("test-guest")
        let sibling = root.appendingPathComponent("sibling.txt")
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: vm, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("preserve sibling".utf8).write(to: sibling)
        let disk = vm.appendingPathComponent("disk.img")
        for entry in ["config.json", "nvram.bin", "disk.img"] {
            try Data(repeating: 2, count: 8192).write(to: vm.appendingPathComponent(entry))
        }
        let exe = bin.appendingPathComponent("lume")
        let script = """
        #!/bin/sh
        case "$1" in
          ls)
            status=stopped
            if test -f "$PWD/running"; then status=running; fi
            printf '[{"name":"test-guest","locationName":"home","status":"%s","diskSize":{"total":8192}}]' "$status";;
          delete)
            test "$2 $3 $4 $5" = 'test-guest --storage home --force' || exit 2
            /bin/rm "$PWD/.lume/sibling.txt" 2>/dev/null && exit 3
            /bin/rm "$PWD/.lume/test-guest/config.json" "$PWD/.lume/test-guest/nvram.bin" "$PWD/.lume/test-guest/disk.img" || exit 4
            /bin/rmdir "$PWD/.lume/test-guest";;
          *) exit 5;;
        esac
        """
        try Data(script.utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
        let rows = try LumeVMReview.discover(home: home, exclusions: [])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.bytes >= 24576)
        #expect(throws: (any Error).self) { try row.remove(exclusions: [disk.path]) }
        let running = home.appendingPathComponent("running")
        try Data().write(to: running)
        #expect(throws: (any Error).self) { try row.remove(exclusions: []) }
        try fm.removeItem(at: running)
        let personal = vm.appendingPathComponent("notes.txt")
        try Data().write(to: personal)
        #expect(try LumeVMReview.discover(home: home, exclusions: []).isEmpty)
        try fm.removeItem(at: personal)
        let previous = root.appendingPathComponent("previous-disk.img")
        try fm.moveItem(at: disk, to: previous)
        try Data(repeating: 2, count: 8192).write(to: disk)
        #expect(throws: (any Error).self) { try row.remove(exclusions: []) }
        let reviewed = try #require(LumeVMReview.discover(home: home, exclusions: []).first)
        try reviewed.remove(exclusions: [])
        #expect(!fm.fileExists(atPath: vm.path))
        #expect(fm.fileExists(atPath: sibling.path))
        #expect(fm.fileExists(atPath: previous.path))
    }
}
