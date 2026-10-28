import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHRuntimeRootTests {
    @Test func createsPrivateOwnerFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try SSHRuntimeRoot(root: root)
        let owner = runtime.url.appendingPathComponent("owner")
        #expect(FileManager.default.fileExists(atPath: owner.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: owner.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func reclaimsOwnerWithWrongStartTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(String(getpid()), isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try "\(getpid()) 1 0\n".write(
            to: directory.appendingPathComponent("owner"),
            atomically: false,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: directory.appendingPathComponent("owner").path)

        SSHRuntimeRoot.reclaimStale(root: root)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func reclaimsDeadOwnerAndRetainsLiveOwnerlessDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exit 0"]
        try child.run()
        child.waitUntilExit()

        let dead = root.appendingPathComponent(String(child.processIdentifier), isDirectory: true)
        try FileManager.default.createDirectory(
            at: dead,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try "\(child.processIdentifier) 1 0\n".write(
            to: dead.appendingPathComponent("owner"),
            atomically: false,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: dead.appendingPathComponent("owner").path)
        let live = root.appendingPathComponent(String(getpid()), isDirectory: true)
        try FileManager.default.createDirectory(
            at: live,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let liveOwner = live.appendingPathComponent("owner")
        guard let current = SSHRuntimeRoot.owner(for: getpid()) else {
            Issue.record("current process identity unavailable")
            return
        }
        try current.text.write(to: liveOwner, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveOwner.path)

        SSHRuntimeRoot.reclaimStale(root: root)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    @Test func retainsLiveOwnerAndDoesNotInvokeReaper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try SSHRuntimeRoot(root: root)
        var reaped = false

        SSHRuntimeRoot.reclaimStale(root: root) { _ in
            reaped = true
            return true
        }

        #expect(!reaped)
        #expect(FileManager.default.fileExists(atPath: runtime.url.path))
    }

    @Test func invokesReaperBeforeRemovingStaleOwnedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let child = root.appendingPathComponent(String(getpid()), isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let owner = child.appendingPathComponent("owner")
        try "\(getpid()) 1 0\n".write(to: owner, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path)
        let tunnelID = UUID()
        let tunnels = child.appendingPathComponent("tunnels", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tunnels,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let record = tunnels.appendingPathComponent("\(tunnelID.uuidString).json")
        let pid: pid_t = 4242
        let json = """
        {"id":"\(tunnelID.uuidString)","pid":\(pid),"realUID":\(getuid()),"effectiveUID":\(getuid()),"startSeconds":7,"startMicroseconds":0,"executablePath":"/fixture/ssh"}
        """
        try json.write(to: record, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        var running = true
        var signals: [Int32] = []

        SSHRuntimeRoot.reclaimStale(root: root) { staleRoot in
            SSHTunnelReaper.reap(
                in: staleRoot,
                inspect: { _ in
                    guard running else { return nil }
                    return SSHAskpassProcessIdentity(
                        pid: pid,
                        parentPID: 1,
                        realUID: getuid(),
                        effectiveUID: getuid(),
                        startSeconds: 7,
                        startMicroseconds: 0,
                        ttyDevice: -1,
                        executablePath: "/fixture/ssh")
                },
                signal: { _, signal in
                    signals.append(signal)
                    running = false
                    return 0
                },
                wait: { _ in })
        }

        #expect(signals == [SIGTERM])
        #expect(!FileManager.default.fileExists(atPath: child.path))
    }

    @Test func retainsStaleOwnedRootWhenReaperCannotVerifyCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let child = root.appendingPathComponent(String(getpid()), isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let owner = child.appendingPathComponent("owner")
        try "\(getpid()) 1 0\n".write(to: owner, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path)

        SSHRuntimeRoot.reclaimStale(root: root) { _ in false }

        #expect(FileManager.default.fileExists(atPath: child.path))
    }
}
