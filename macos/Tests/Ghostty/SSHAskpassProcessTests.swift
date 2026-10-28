import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHAskpassProcessTests {
    private let app = "/fixture/Chostty.app/Contents/MacOS/Chostty"
    private let tty: dev_t = 17

    @Test func readsCurrentKernelIdentityWithoutInventingMissingProcesses() throws {
        let current = try #require(SSHAskpassProcessIdentity.read(getpid()))
        #expect(current.pid == getpid())
        #expect(current.parentPID == getppid())
        #expect(current.realUID == getuid())
        #expect(current.effectiveUID == geteuid())
        #expect(current.executablePath.hasPrefix("/"))
        #expect(SSHAskpassProcessIdentity.read(0) == nil)
        #expect(SSHAskpassProcessIdentity.read(1) == nil)
        #expect(SSHAskpassProcessIdentity.read(-1) == nil)
        #expect(SSHAskpassProcess.ttyDevice(named: "/tmp/not-a-tty") == nil)
    }

    @Test func rejectsKernelIdentityChangesDuringExecutableLookup() throws {
        let info = try #require(SSHRuntimeRoot.processInfo(for: getpid()))
        #expect(SSHAskpassProcessIdentity.sameKernelProcess(info, info))
        let fields: [WritableKeyPath<proc_bsdinfo, UInt32>] = [
            \.pbi_pid, \.pbi_ppid, \.pbi_ruid, \.pbi_uid, \.e_tdev
        ]
        for field in fields {
            var changed = info
            changed[keyPath: field] &+= 1
            #expect(!SSHAskpassProcessIdentity.sameKernelProcess(info, changed))
        }
        var changed = info
        changed.pbi_start_tvsec &+= 1
        #expect(!SSHAskpassProcessIdentity.sameKernelProcess(info, changed))
        changed = info
        changed.pbi_start_tvusec &+= 1
        #expect(!SSHAskpassProcessIdentity.sameKernelProcess(info, changed))
    }

    @Test func pinsOnceAndDoesNotConsultRewrittenPIDFileDuringValidation() throws {
        try withPIDFile("101\n") { file in
            let nodes = chain()
            let pinned = try #require(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty, channelCreatedAt: 101,
                inspect: { $0 == 101 ? nodes[3] : nil }))
            try "999\n".write(to: file, atomically: false, encoding: .utf8)
            #expect(SSHAskpassProcess.validates(
                chain: nodes, peerUID: getuid(), supervisor: pinned, appExecutablePath: app))
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty, channelCreatedAt: 101,
                inspect: { $0 == 101 ? nodes[3] : nil }) == nil)
        }
    }

    @Test(arguments: ["", "1\n", "0\n", "-2\n", "+101\n", "101 extra\n", "101\r\n", "١٠١\n",
                     "99999999999999999\n", "2147483648\n"])
    func rejectsMalformedOrOversizedPIDFiles(_ text: String) throws {
        try withPIDFile(text) { file in
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty, channelCreatedAt: 100,
                inspect: { _ in node(101, parent: 99, start: 100) }) == nil)
        }
    }

    @Test func rejectsSymlinkFIFOForeignOwnerAndUnsafeAnchors() throws {
        try withPIDFile("101\n") { file in
            let link = file.deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let fifo = file.deletingLastPathComponent().appendingPathComponent("fifo")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            let inspect: SSHAskpassProcess.Inspector = { _ in node(101, parent: 99, start: 100) }
            for unsafe in [link, fifo, file.deletingLastPathComponent()] {
                #expect(SSHAskpassProcess.pinSupervisor(
                    pidFile: unsafe, ttyDevice: tty, channelCreatedAt: 100, inspect: inspect) == nil)
            }
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty, channelCreatedAt: 100,
                uid: getuid() + 1, inspect: inspect) == nil)
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty + 1, channelCreatedAt: 100, inspect: inspect) == nil)
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty, channelCreatedAt: 102, inspect: inspect) == nil)
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: -1, channelCreatedAt: 100, inspect: inspect) == nil)
            #expect(SSHAskpassProcess.pinSupervisor(
                pidFile: file, ttyDevice: tty, channelCreatedAt: .nan, inspect: inspect) == nil)
        }
    }

    @Test func rejectsChangedKernelSupervisorCredentialsAndStart() throws {
        try withPIDFile("101\n") { file in
            let invalid = [
                node(101, parent: 99, start: 100, realUID: getuid() + 1),
                node(101, parent: 99, start: 100, effectiveUID: getuid() + 1),
                node(102, parent: 99, start: 100),
                node(101, parent: 99, start: 98),
                node(101, parent: 99, start: 100, microseconds: 1_000_000)
            ]
            for value in invalid {
                #expect(SSHAskpassProcess.pinSupervisor(
                    pidFile: file, ttyDevice: tty, channelCreatedAt: 100,
                    inspect: { _ in value }) == nil)
            }
        }
    }

    @Test func requiresExactThreeHopsSystemSSHAndBothAppExecutables() throws {
        let nodes = chain()
        let pinned = nodes[3]
        #expect(valid(nodes, pinned))
        #expect(!SSHAskpassProcess.validates(
            chain: nodes, peerUID: getuid() + 1, supervisor: pinned, appExecutablePath: app))
        #expect(!valid(Array(nodes.dropLast()), pinned))
        #expect(!valid(nodes + [node(99, parent: 1, start: 50)], pinned))
        for index in 0..<3 {
            var changed = nodes
            changed[index] = node(
                nodes[index].pid, parent: nodes[index].parentPID, start: nodes[index].startSeconds,
                executable: "/other/client")
            #expect(!valid(changed, pinned))
        }
        var gateway = nodes
        gateway[2] = node(102, parent: 101, start: 200, executable: "/usr/bin/ssh")
        #expect(!valid(gateway, pinned))
    }

    @Test func rejectsForeignTTYUIDBrokenParentLinksAndPIDReuse() {
        let nodes = chain()
        let pinned = nodes[3]
        for index in nodes.indices {
            let old = nodes[index]
            let replacements = [
                node(old.pid, parent: old.parentPID, start: old.startSeconds, device: tty + 1, executable: old.executablePath),
                node(old.pid, parent: old.parentPID, start: old.startSeconds, realUID: getuid() + 1, executable: old.executablePath),
                node(old.pid, parent: old.parentPID, start: old.startSeconds, effectiveUID: getuid() + 1, executable: old.executablePath),
                node(old.pid, parent: 88, start: old.startSeconds, executable: old.executablePath)
            ]
            for replacement in replacements {
                var changed = nodes
                changed[index] = replacement
                #expect(!valid(changed, pinned))
            }
        }
        var reused = nodes
        reused[3] = node(101, parent: 99, start: 101, executable: "/bin/sh")
        #expect(!valid(reused, pinned))
        var reversedStarts = nodes
        reversedStarts[1] = node(103, parent: 102, start: 500, executable: "/usr/bin/ssh")
        #expect(!valid(reversedStarts, pinned))
    }

    @Test func kernelWalkRejectsCyclesMissingNodesAndWrongReturnedPID() {
        let nodes = chain()
        let table = Dictionary(uniqueKeysWithValues: nodes.map { ($0.pid, $0) })
        #expect(SSHAskpassProcess.chain(from: 104, inspect: { table[$0] }) == nodes)
        #expect(SSHAskpassProcess.chain(from: 105, inspect: { table[$0] }) == nil)
        #expect(SSHAskpassProcess.chain(from: 104, inspect: { _ in nodes[0] }) == nil)
        #expect(SSHAskpassProcess.chain(from: 104, inspect: { pid in
            node(pid, parent: pid, start: 100)
        }) == nil)
    }

    private func valid(_ nodes: [SSHAskpassProcessIdentity], _ pinned: SSHAskpassProcessIdentity) -> Bool {
        SSHAskpassProcess.validates(chain: nodes, peerUID: getuid(), supervisor: pinned, appExecutablePath: app)
    }

    private func chain() -> [SSHAskpassProcessIdentity] {
        [node(104, parent: 103, start: 400, executable: app),
         node(103, parent: 102, start: 300, executable: "/usr/bin/ssh"),
         node(102, parent: 101, start: 200, executable: app),
         node(101, parent: 99, start: 100, executable: "/bin/sh")]
    }

    private func node(
        _ pid: pid_t, parent: pid_t, start: Int64, microseconds: Int64 = 0,
        device: dev_t = 17, realUID: uid_t = getuid(), effectiveUID: uid_t = geteuid(),
        executable: String = "/bin/sh"
    ) -> SSHAskpassProcessIdentity {
        SSHAskpassProcessIdentity(
            pid: pid, parentPID: parent, realUID: realUID, effectiveUID: effectiveUID,
            startSeconds: start, startMicroseconds: microseconds, ttyDevice: device, executablePath: executable)
    }

    private func withPIDFile(_ text: String, body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pid")
        try text.write(to: file, atomically: false, encoding: .utf8)
        try body(file)
    }
}
