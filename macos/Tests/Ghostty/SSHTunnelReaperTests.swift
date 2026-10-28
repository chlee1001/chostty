import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHTunnelReaperTests {
    @Test func writesPrivateRecordFromLiveProcessIdentity() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()

        let record = try SSHTunnelReaper.writeRecord(for: id, sshPID: getpid(), in: root)

        #expect(record.lastPathComponent == "\(id.uuidString).json")
        #expect(Self.permissions(of: record) == 0o600)
        #expect((try Data(contentsOf: record)).count > 0)
        SSHTunnelReaper.removeRecord(for: id, in: root)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test func reapsMatchingOwnedProcessBeforeRemovingRecord() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let pid: pid_t = 4242
        try Self.writeRecord(id: id, pid: pid, start: 7, in: root)
        var running = true
        var signals: [Int32] = []

        let reaped = SSHTunnelReaper.reap(
            in: root,
            inspect: { _ in running ? Self.identity(pid: pid, start: 7) : nil },
            signal: { _, signal in
                signals.append(signal)
                running = false
                return 0
            },
            wait: { _ in })

        #expect(reaped)
        #expect(signals == [SIGTERM])
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("tunnels/\(id.uuidString).json").path))
    }

    @Test func neverSignalsMismatchedProcessIdentity() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let pid: pid_t = 4242
        try Self.writeRecord(id: id, pid: pid, start: 7, in: root)
        var signals: [Int32] = []

        let reaped = SSHTunnelReaper.reap(
            in: root,
            inspect: { _ in Self.identity(pid: pid, start: 8) },
            signal: { _, signal in
                signals.append(signal)
                return 0
            },
            wait: { _ in })

        #expect(reaped)
        #expect(signals.isEmpty)
    }

    @Test func rejectsSymlinkRecordWithoutInspectingOrSignaling() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let external = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        try "{}".write(to: external, atomically: false, encoding: .utf8)
        let tunnels = root.appendingPathComponent("tunnels", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tunnels,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(
            at: tunnels.appendingPathComponent("\(id.uuidString).json"),
            withDestinationURL: external)
        var inspected = false
        var signaled = false

        let reaped = SSHTunnelReaper.reap(
            in: root,
            inspect: { _ in
                inspected = true
                return nil
            },
            signal: { _, _ in
                signaled = true
                return 0
            },
            wait: { _ in })

        #expect(!reaped)
        #expect(!inspected)
        #expect(!signaled)
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test func rejectsMalformedRecordWithoutInspectingOrSignaling() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let tunnels = root.appendingPathComponent("tunnels", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tunnels,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let record = tunnels.appendingPathComponent("\(id.uuidString).json")
        try "{}".write(to: record, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        var inspected = false
        var signaled = false

        let reaped = SSHTunnelReaper.reap(
            in: root,
            inspect: { _ in
                inspected = true
                return nil
            },
            signal: { _, _ in
                signaled = true
                return 0
            },
            wait: { _ in })

        #expect(!reaped)
        #expect(!inspected)
        #expect(!signaled)
    }

    @Test func anUnreadableEntryDoesNotShieldTheRecordsAfterIt() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let pid: pid_t = 4242
        try Self.writeRecord(id: id, pid: pid, start: 7, in: root)
        let stray = root.appendingPathComponent("tunnels/.DS_Store")
        try Data().write(to: stray)
        var running = true
        var signals: [Int32] = []

        let reaped = SSHTunnelReaper.reap(
            in: root,
            inspect: { _ in running ? Self.identity(pid: pid, start: 7) : nil },
            signal: { _, signal in
                signals.append(signal)
                running = false
                return 0
            },
            wait: { _ in })

        #expect(!reaped)
        #expect(signals == [SIGTERM])
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func discardsInterruptedTemporaryWriteWithoutBlockingReclaim() throws {
        let root = try Self.runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try Self.writeRecord(id: id, pid: 4_242, start: 7, in: root)
        let tunnels = root.appendingPathComponent("tunnels", isDirectory: true)
        let temporary = tunnels.appendingPathComponent(".\(UUID().uuidString).json.\(UUID().uuidString).tmp")
        try "partial".write(to: temporary, atomically: false, encoding: .utf8)
        var signals: [Int32] = []

        let reaped = SSHTunnelReaper.reap(
            in: root,
            inspect: { _ in nil },
            signal: { _, signal in
                signals.append(signal)
                return 0
            },
            wait: { _ in })

        #expect(reaped)
        #expect(signals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tunnels.path).isEmpty)
    }

    private static func runtimeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    private static func writeRecord(id: UUID, pid: pid_t, start: Int64, in root: URL) throws {
        let tunnels = root.appendingPathComponent("tunnels", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tunnels,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let json = """
        {"id":"\(id.uuidString)","pid":\(pid),"realUID":\(getuid()),"effectiveUID":\(getuid()),"startSeconds":\(start),"startMicroseconds":0,"executablePath":"/fixture/ssh"}
        """
        let url = tunnels.appendingPathComponent("\(id.uuidString).json")
        try json.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func identity(pid: pid_t, start: Int64) -> SSHAskpassProcessIdentity {
        SSHAskpassProcessIdentity(
            pid: pid,
            parentPID: 1,
            realUID: getuid(),
            effectiveUID: getuid(),
            startSeconds: start,
            startMicroseconds: 0,
            ttyDevice: -1,
            executablePath: "/fixture/ssh")
    }

    private static func permissions(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber
        else { return -1 }
        return value.intValue
    }
}
