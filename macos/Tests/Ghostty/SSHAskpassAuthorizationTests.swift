import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHAskpassAuthorizationTests {
    @Test func issuesTokenWithoutFetchingPassword() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()

        let token = try #require(fixture.prepare(authorization))
        #expect(token.count == 64)
        #expect(token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        #expect(fixture.store.passwordFetches == 0)
        #expect(authorization.authority.supervisor(fixture.request()) == fixture.supervisor)
    }

    @Test func sshConfigModeDoesNotInspectCredentialsOrWarn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeMetadata(auth: .sshConfig)
        let authorization = fixture.authorization()
        #expect(fixture.prepare(authorization) == nil)
        #expect(fixture.store.targetLookups == 0)
        #expect(fixture.store.passwordFetches == 0)
        #expect(fixture.warnings.values.isEmpty)
    }

    @Test func stalePreparationAndRevocationNeverIssueAToken() throws {
        let fixture = try Fixture(blockTarget: true)
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let result = ResultBox<String?>()
        let completed = DispatchSemaphore(value: 0)
        authorization.prepare(reference: fixture.reference, launchID: fixture.launchID, sequence: 1,
                              supervisor: fixture.supervisor, brokerAvailable: true) { token in
            result.value = token
            completed.signal()
        }
        #expect(fixture.store.targetStarted.wait(timeout: .now() + 1) == .success)
        authorization.revoke(launchID: fixture.launchID)
        fixture.store.allowTarget.signal()
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect((result.value ?? nil) == nil)
    }

    @Test func reservesOnlyTheFirstExactPasswordAttemptForAnSSHIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        _ = try #require(fixture.prepare(authorization))
        let authority = authorization.authority

        #expect(authority.reserve(fixture.request(prompt: "not a password"), fixture.ssh) == nil)
        #expect(authority.reserve(SSHAskpassRequest(nonce: fixture.nonce, mode: "confirm", prompt: fixture.passwordPrompt), fixture.ssh) == nil)
        let reservation = try #require(authority.reserve(fixture.request(), fixture.ssh))
        #expect(authority.reserve(fixture.request(), fixture.ssh) == nil)
        #expect(authority.reserve(fixture.request(), fixture.otherSSH) == nil)
        #expect(reservation.target == fixture.target)
    }

    @Test func revalidationRejectsChangedConfigurationMetadataAndTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        _ = try #require(fixture.prepare(authorization))
        let authority = authorization.authority
        let reservation = try #require(authority.reserve(fixture.request(), fixture.ssh))
        #expect(authority.revalidate(reservation, fixture.request(), fixture.ssh))

        try fixture.writeManagedHost(hostName: "changed.example.test")
        #expect(!authority.revalidate(reservation, fixture.request(), fixture.ssh))
        try fixture.writeManagedHost(hostName: "example.test")
        try fixture.writeMetadata(auth: .sshConfig)
        #expect(!authority.revalidate(reservation, fixture.request(), fixture.ssh))
        try fixture.writeMetadata(auth: .keychain)
        fixture.store.target = try SSHTargetFingerprint(hostID: fixture.hostID, user: "alice", hostName: "changed.example.test", port: 22)
        #expect(!authority.revalidate(reservation, fixture.request(), fixture.ssh))
    }

    @Test func expiryAndOlderObservedEventsCannotRevokeNewerGrant() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = ClockBox()
        let authorization = fixture.authorization(now: { clock.now() })
        _ = try #require(fixture.prepare(authorization, sequence: 4))
        authorization.observed(launchID: fixture.launchID, sequence: 3)
        #expect(authorization.authority.supervisor(fixture.request()) == fixture.supervisor)
        clock.advance(by: .seconds(121))
        #expect(authorization.authority.supervisor(fixture.request()) == nil)
    }

    @Test func rejectionWarningRequiresAnActuallyServedSecret() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        _ = try #require(fixture.prepare(authorization))
        let authority = authorization.authority
        let reservation = try #require(authority.reserve(fixture.request(), fixture.ssh))
        #expect(authority.reserve(fixture.request(), fixture.ssh) == nil)
        #expect(fixture.warnings.values.isEmpty)
        authority.status(.served(reservation.identifier))
        #expect(authority.reserve(fixture.request(), fixture.otherSSH) == nil)
        #expect(fixture.warnings.values.isEmpty)
        #expect(authority.reserve(fixture.request(), fixture.ssh) == nil)
        let warnings = fixture.warnings.values
        #expect(warnings.count == 1)
        #expect(warnings.first?.0 == fixture.hostID)
        #expect(warnings.first?.1 == "Saved password was rejected.")
    }

    private final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let hostID = UUID()
        let launchID = UUID()
        let alias = "fixture"
        let nonce = Array(repeating: UInt8(7), count: 32)
        let target: SSHTargetFingerprint
        let paths: SSHPaths
        let reference: SSHHostReference
        let supervisor: SSHAskpassProcessIdentity
        let ssh: SSHAskpassProcessIdentity
        let otherSSH: SSHAskpassProcessIdentity
        let store: FakeStore
        let warnings = WarningBox()

        init(blockTarget: Bool = false) throws {
            paths = SSHPaths(home: root, runtimeRoot: root, environment: [:])
            target = try SSHTargetFingerprint(hostID: hostID, user: "alice", hostName: "example.test", port: 22)
            reference = SSHHostReference(source: .managed(hostID: hostID), alias: alias)
            supervisor = Self.identity(400, parent: 1)
            ssh = Self.identity(300, parent: 400, path: "/usr/bin/ssh")
            otherSSH = Self.identity(301, parent: 400, path: "/usr/bin/ssh")
            store = FakeStore(target: target, blockTarget: blockTarget)
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try Self.writeManagedHost(to: paths.managedHostsFile, hostID: hostID, alias: alias)
            try writeMetadata(auth: .keychain)
        }

        func authorization(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) -> SSHAskpassAuthorization {
            SSHAskpassAuthorization(paths: paths, secretStore: store, warning: { [warnings] hostID, warning in
                warnings.append((hostID, warning))
            }, now: now, randomBytes: { [nonce] count in count == nonce.count ? nonce : nil })
        }

        func prepare(_ authorization: SSHAskpassAuthorization, sequence: Int = 1) -> String? {
            let result = ResultBox<String?>()
            let completed = DispatchSemaphore(value: 0)
            authorization.prepare(reference: reference, launchID: launchID, sequence: sequence,
                                  supervisor: supervisor, brokerAvailable: true) { token in
                result.value = token
                completed.signal()
            }
            guard completed.wait(timeout: .now() + 1) == .success else { return nil }
            return result.value ?? nil
        }

        func request(prompt: String? = nil) -> SSHAskpassRequest {
            SSHAskpassRequest(nonce: nonce, mode: nil, prompt: prompt ?? passwordPrompt)
        }

        var passwordPrompt: String { "alice@example.test's password: " }

        func writeMetadata(auth: SSHManagedHostAuth) throws {
            let metadata = try SSHHostMetadataFile(hosts: [hostID: try SSHManagedHostMetadata(auth: auth)])
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: paths.metadataFile, options: .atomic)
        }

        func writeManagedHost(hostName: String) throws {
            try Self.writeManagedHost(to: paths.managedHostsFile, hostID: hostID, alias: alias, hostName: hostName)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func writeManagedHost(to url: URL, hostID: UUID, alias: String, hostName: String = "example.test") throws {
            let text = "# chostty-host-id: \(hostID.uuidString)\nHost \(alias)\n  HostName \(hostName)\n  User alice\n  Port 22\n"
            try Data(text.utf8).write(to: url, options: .atomic)
        }

        private static func identity(_ pid: pid_t, parent: pid_t, path: String = "/fixture/Chostty.app/Contents/MacOS/Chostty") -> SSHAskpassProcessIdentity {
            SSHAskpassProcessIdentity(pid: pid, parentPID: parent, realUID: getuid(), effectiveUID: getuid(),
                                      startSeconds: Int64(pid), startMicroseconds: 1, ttyDevice: 7, executablePath: path)
        }
    }

    private final class FakeStore: SSHSecretStore, @unchecked Sendable {
        var target: SSHTargetFingerprint
        var passwordFetches = 0
        var targetLookups = 0
        let targetStarted = DispatchSemaphore(value: 0)
        let allowTarget = DispatchSemaphore(value: 0)
        private let blockTarget: Bool

        init(target: SSHTargetFingerprint, blockTarget: Bool) {
            self.target = target
            self.blockTarget = blockTarget
        }

        func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer {
            passwordFetches += 1
            throw SSHSecretStoreError.notFound
        }

        func target(for hostID: UUID) throws -> SSHTargetFingerprint {
            targetLookups += 1
            if blockTarget {
                targetStarted.signal()
                _ = allowTarget.wait(timeout: .now() + 1)
            }
            return target
        }

        func setPassword(_ secret: SSHSecretBuffer, for hostID: UUID, target: SSHTargetFingerprint, label: String) throws {}
        func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws {}
        func deletePassword(for hostID: UUID) throws {}
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?

        var value: Value? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private final class WarningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(UUID, String?)] = []

        var values: [(UUID, String?)] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func append(_ warning: (UUID, String?)) {
            lock.lock()
            stored.append(warning)
            lock.unlock()
        }
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock().now

        func now() -> ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }

        func advance(by duration: Duration) {
            lock.lock()
            instant = instant.advanced(by: duration)
            lock.unlock()
        }
    }
}
