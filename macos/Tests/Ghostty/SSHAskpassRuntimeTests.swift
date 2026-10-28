import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHAskpassRuntimeTests {
    @Test func rejectsShortOversizedAndMalformedFramesBeforeAuthority() throws {
        #expect(SSHAskpassBroker.decodeRequest([]) == nil)
        #expect(SSHAskpassBroker.decodeRequest([0x43, 0x41, 0x50, 0x31, 1]) == nil)
        #expect(SSHAskpassBroker.decodeRequest([0x43, 0x41, 0x50, 0x31, 2] + Array(repeating: 0, count: 35)) == nil)

        let nonce = Array(repeating: UInt8(7), count: 32)
        let prompt = Array("alice@example.test's password: ".utf8)
        let frame = try #require(SSHAskpassBroker.encodeRequest(nonce: nonce, mode: nil, prompt: prompt))
        #expect(SSHAskpassBroker.decodeRequest(Array(frame.dropFirst(4)))?.nonce == nonce)
        #expect(SSHAskpassBroker.encodeRequest(nonce: nonce, mode: nil,
                                                prompt: Array(repeating: 65, count: 4_097)) == nil)
        #expect(SSHAskpassBroker.encodeRequest(nonce: Array(repeating: 1, count: 31), mode: nil, prompt: prompt) == nil)
    }

    @Test(arguments: [0, 215, 216, 255, 256, 4096])
    func frameLengthsCrossByteBoundariesWithoutTruncation(_ length: Int) throws {
        let prompt = String(repeating: "x", count: length)
        let nonce = Array(repeating: UInt8(7), count: 32)
        let frame = try #require(SSHAskpassBroker.encodeRequest(nonce: nonce, mode: nil, prompt: Array(prompt.utf8)))
        let declared = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(declared == UInt32(frame.count - 4))
        let decoded = try #require(SSHAskpassBroker.decodeRequest(Array(frame.dropFirst(4))))
        #expect(decoded.prompt == prompt)
        #expect(decoded.nonce == nonce)
    }

    @Test func rejectsUnsafeFallbackDirectoryWithoutRepairingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: SSHAskpassBroker.Error.unsafeFallback) {
            try SSHAskpassBroker.prepareFallbackDirectory(root)
        }
        var info = stat()
        #expect(lstat(root.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o755)
    }

    @Test func createsAPrivateListenerBeforeAnyCredentialHydration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try SSHTargetFingerprint(hostID: UUID(), user: "alice", hostName: "example.test", port: 22)
        let store = FakeStore(target: target)
        let app = "/bin/sh"
        let broker = try SSHAskpassBroker(
            runtimeRoot: root,
            appProcessID: 777,
            appExecutablePath: app,
            secretStore: store,
            authority: SSHAskpassBrokerAuthority(
                supervisor: { _ in nil },
                reserve: { _, _ in nil },
                revalidate: { _, _, _ in false },
                status: { _ in }),
            inspect: { _ in nil })
        var info = stat()
        #expect(lstat(broker.socketURL.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600)
        broker.start()
        broker.start()
        broker.stop()
        broker.stop()
        #expect(lstat(broker.socketURL.path, &info) != 0)
        #expect(store.passwordFetches == 0)
    }

    @Test func transientAcceptFailureBacksOffThenAcceptsAClient() throws {
        let root = try runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = AcceptScript(errors: [EMFILE])
        let broker = try makeBroker(root: root, acceptClient: { script.accept($0) })
        broker.start()
        let client = try #require(connect(to: broker.socketURL))
        defer { _ = Darwin.close(client) }
        #expect(eventually { script.calls >= 2 })
        #expect(broker.isAvailable)
        broker.stop()
    }

    @Test func fatalAcceptFailureMakesBrokerUnavailableAndUnlinksSocket() throws {
        let root = try runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = try makeBroker(root: root, acceptClient: { _ in .failed(EBADF) })
        broker.start()
        #expect(eventually { !broker.isAvailable })
        var info = stat()
        #expect(lstat(broker.socketURL.path, &info) != 0)
    }

    @Test func authoritySelectsTheSupervisorFromEachRequestNonce() {
        let app = "/fixture/Chostty.app/Contents/MacOS/Chostty"
        let first = identity(400, parent: 1, path: app, tty: 21)
        let second = identity(500, parent: 1, path: app, tty: 22)
        let pins = PinMap([
            Array(repeating: 1, count: 32): first,
            Array(repeating: 2, count: 32): second,
        ])
        let authority = SSHAskpassBrokerAuthority(
            supervisor: { pins.value(for: $0.nonce) },
            reserve: { _, _ in nil },
            revalidate: { _, _, _ in false },
            status: { _ in })
        #expect(authority.supervisor(request(nonce: 1)) == first)
        #expect(authority.supervisor(request(nonce: 2)) == second)
        #expect(authority.supervisor(request(nonce: 3)) == nil)
    }

    @Test(arguments: ["stable", "changed-after-ACL", "starts-after-accept"])
    func credentialReleaseRechecksIdentityAfterAuthorityIO(_ scenario: String) throws {
        let root = try runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = "/bin/bash"
        let target = try SSHTargetFingerprint(hostID: UUID(), user: "alice", hostName: "example.test", port: 22)
        let store = FakeStore(target: target)
        let state = RevalidationState(invalidates: scenario == "changed-after-ACL")
        let supervisor = identity(103, parent: 1, path: app, tty: 21, start: 100)
        let nodes = [
            identity(getpid(), parent: 101, path: app, tty: 21,
                     start: scenario == "starts-after-accept" ? Int64(time(nil)) + 5 : 400),
            identity(101, parent: 102, path: "/usr/bin/ssh", tty: 21, start: 300),
            identity(102, parent: 103, path: app, tty: 21, start: 200), supervisor
        ]
        let table = Dictionary(uniqueKeysWithValues: nodes.map { ($0.pid, $0) })
        let broker = try SSHAskpassBroker(
            runtimeRoot: root, appExecutablePath: app, secretStore: store,
            authority: SSHAskpassBrokerAuthority(
                supervisor: { _ in supervisor },
                reserve: { _, _ in
                    SSHAskpassReservation(target: target,
                                          expiresAt: ContinuousClock().now.advanced(by: .seconds(10)), identifier: UUID())
                },
                revalidate: { _, _, _ in state.revalidate() },
                status: { _ in }),
            inspect: { state.identityIsValid ? table[$0] : nil })
        broker.start()
        defer { broker.stop() }
        let client = try #require(connect(to: broker.socketURL))
        defer { _ = Darwin.close(client) }
        let frame = try #require(SSHAskpassBroker.encodeRequest(
            nonce: Array(repeating: 7, count: 32), mode: nil,
            prompt: Array("alice@example.test's password: ".utf8)))
        #expect(frame.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) } == frame.count)
        let header = try #require(readResponseHeader(client))
        #expect(Array(header.prefix(4)) == [0x43, 0x41, 0x50, 0x31])
        #expect(header[5] == (scenario == "stable" ? 1 : 0))
        #expect(store.passwordFetches == (scenario == "starts-after-accept" ? 0 : 1))
        #expect(state.calls == (scenario == "starts-after-accept" ? 0 : 2))
    }

    @Test(arguments: ["answered", "declined", "other-watchdog", "homebrew-ssh"])
    func tunnelRequestsAreAnsweredOnlyForTheRecordedWatchdog(_ scenario: String) throws {
        let root = try runtimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = "/bin/bash"
        let owner = identity(103, parent: 1, path: app, tty: 0, start: 100)
        let watchdog = identity(102, parent: 103, path: "/bin/bash", tty: 0, start: 200)
        let nodes = [
            identity(getpid(), parent: 101, path: app, tty: 0, start: 400),
            identity(101, parent: 102, path: scenario == "homebrew-ssh" ? "/opt/homebrew/bin/ssh" : "/usr/bin/ssh",
                     tty: 0, start: 300),
            watchdog, owner,
        ]
        let table = Dictionary(uniqueKeysWithValues: nodes.map { ($0.pid, $0) })
        let recorded = scenario == "other-watchdog" ? identity(102, parent: 103, path: "/bin/bash", tty: 0, start: 201) : watchdog
        let calls = TunnelCalls()
        let target = try SSHTargetFingerprint(hostID: UUID(), user: "alice", hostName: "example.test", port: 22)
        let broker = try SSHAskpassBroker(
            runtimeRoot: root, appExecutablePath: app, secretStore: FakeStore(target: target),
            authority: SSHAskpassBrokerAuthority(
                supervisor: { _ in nil }, reserve: { _, _ in nil },
                revalidate: { _, _, _ in false }, status: { _ in }),
            tunnelAuthority: SSHAskpassTunnelAuthority(
                launch: { $0.nonce == Array(repeating: 9, count: 32)
                    ? SSHAskpassTunnelLaunch(watchdog: recorded, owner: owner) : nil },
                answer: { _, ssh in
                    calls.answered(ssh.pid)
                    let reply: [UInt8] = Array("yes".utf8)
                    return scenario == "declined" ? nil : reply.withUnsafeBytes { SSHSecretBuffer(copying: $0) }
                },
                refused: { _ in calls.refused() }),
            inspect: { table[$0] })
        broker.start()
        defer { broker.stop() }
        let client = try #require(connect(to: broker.socketURL))
        defer { _ = Darwin.close(client) }
        let frame = try #require(SSHAskpassBroker.encodeRequest(
            nonce: Array(repeating: 9, count: 32), mode: nil, prompt: Array("Password: ".utf8)))
        #expect(frame.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) } == frame.count)
        let header = try #require(readResponseHeader(client))
        #expect(Array(header.prefix(4)) == [0x43, 0x41, 0x50, 0x31])
        #expect(header[5] == (scenario == "answered" ? 1 : 0))
        let verified = scenario == "answered" || scenario == "declined"
        #expect(calls.answers == (verified ? [101] : []))
        #expect(calls.refusals == (verified ? 0 : 1))
    }

    @Test func tunnelChainValidationNeedsTheSameWatchdogAndOwner() {
        let app = "/fixture/Chostty.app/Contents/MacOS/Chostty"
        let owner = identity(400, parent: 1, path: app, tty: 0, start: 100)
        let watchdog = identity(350, parent: 400, path: "/bin/sh", tty: 0, start: 200)
        let ssh = identity(300, parent: 350, path: "/usr/bin/ssh", tty: 0, start: 300)
        let helper = identity(200, parent: 300, path: app, tty: 0, start: 400)
        // The /bin/sh trampoline execs another shell; the kernel process is the same.
        let execed = identity(350, parent: 400, path: "/bin/bash", tty: 0, start: 200)
        #expect(SSHAskpassProcess.validatesTunnel(chain: [helper, ssh, execed, owner], peerUID: getuid(),
                                                 watchdog: watchdog, owner: owner, appExecutablePath: app))
        #expect(!SSHAskpassProcess.validatesTunnel(chain: [helper, ssh, watchdog, owner], peerUID: getuid() &+ 1,
                                                  watchdog: watchdog, owner: owner, appExecutablePath: app))
        let reused = identity(350, parent: 400, path: "/bin/sh", tty: 0, start: 999)
        #expect(!SSHAskpassProcess.validatesTunnel(chain: [helper, ssh, reused, owner], peerUID: getuid(),
                                                  watchdog: watchdog, owner: owner, appExecutablePath: app))
        let notTheApp = identity(200, parent: 300, path: "/tmp/Chostty", tty: 0, start: 400)
        #expect(!SSHAskpassProcess.validatesTunnel(chain: [notTheApp, ssh, watchdog, owner], peerUID: getuid(),
                                                  watchdog: watchdog, owner: owner, appExecutablePath: app))
    }

    @Test func reservationExpiryUsesMonotonicInstants() throws {
        let clock = ContinuousClock()
        let target = try SSHTargetFingerprint(hostID: UUID(), user: "alice", hostName: "example.test", port: 22)
        let expired = SSHAskpassReservation(target: target, expiresAt: clock.now, identifier: UUID())
        let live = SSHAskpassReservation(
            target: target,
            expiresAt: clock.now.advanced(by: .seconds(120)),
            identifier: UUID())
        #expect(expired.expiresAt <= clock.now)
        #expect(live.expiresAt > clock.now)
    }

    @Test func acceptsOnlyExactPromptBytesAndNeverTreatsModesAsPasswords() throws {
        let target = try SSHTargetFingerprint(hostID: UUID(), user: "alice", hostName: "example.test", port: 22)
        #expect(SSHAskpassPromptClassifier.classify(prompt: "alice@example.test's password: ", mode: nil, target: target) == .password)
        #expect(SSHAskpassPromptClassifier.classify(prompt: "alice@example.test’s password: ", mode: nil, target: target) == .passthrough)
        #expect(SSHAskpassPromptClassifier.classify(prompt: "alice@example.test's password: ", mode: "confirm", target: target) == .passthrough)
        #expect(SSHAskpassPromptClassifier.classify(prompt: "", mode: "none", target: target) == .notify)
    }

    @Test func chainValidationRejectsUIDClaimsAndProxyDepth() {
        let app = "/fixture/Chostty.app/Contents/MacOS/Chostty"
        let tty: dev_t = 21
        let supervisor = identity(400, parent: 1, path: app, tty: tty)
        let ssh = identity(300, parent: 400, path: "/usr/bin/ssh", tty: tty)
        let helper = identity(200, parent: 300, path: app, tty: tty)
        let chain = [helper, ssh, identity(250, parent: 300, path: app, tty: tty), supervisor]
        #expect(!SSHAskpassProcess.validates(chain: chain, peerUID: getuid(), supervisor: supervisor, appExecutablePath: app))
        #expect(!SSHAskpassProcess.validates(chain: [helper, ssh, identity(250, parent: 300, path: app, tty: tty)],
                                              peerUID: getuid() &+ 1, supervisor: supervisor, appExecutablePath: app))
    }

    private func identity(_ pid: pid_t, parent: pid_t, path: String, tty: dev_t, start: Int64? = nil) -> SSHAskpassProcessIdentity {
        SSHAskpassProcessIdentity(pid: pid, parentPID: parent, realUID: getuid(), effectiveUID: getuid(),
                                  startSeconds: start ?? Int64(pid), startMicroseconds: 1, ttyDevice: tty, executablePath: path)
    }

    private func request(nonce byte: UInt8) -> SSHAskpassRequest {
        SSHAskpassRequest(nonce: Array(repeating: byte, count: 32), mode: nil, prompt: "")
    }

    private func runtimeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeBroker(
        root: URL,
        acceptClient: @escaping @Sendable (Int32) -> SSHAskpassAcceptOutcome
    ) throws -> SSHAskpassBroker {
        let target = try SSHTargetFingerprint(hostID: UUID(), user: "alice", hostName: "example.test", port: 22)
        return try SSHAskpassBroker(
            runtimeRoot: root,
            appProcessID: 777,
            appExecutablePath: "/bin/sh",
            secretStore: FakeStore(target: target),
            authority: SSHAskpassBrokerAuthority(
                supervisor: { _ in nil },
                reserve: { _, _ in nil },
                revalidate: { _, _, _ in false },
                status: { _ in }),
            inspect: { _ in nil },
            acceptClient: acceptClient)
    }

    private func connect(to url: URL) -> Int32? {
        let bytes = Array(url.path.utf8)
        guard bytes.count + 1 <= 104 else { return nil }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let flags = fcntl(descriptor, F_GETFD)
        var noSigPipe: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { _ = Darwin.close(descriptor); return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address) { raw in
            bytes.withUnsafeBytes {
                raw.baseAddress!.advanced(by: 2).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func readResponseHeader(_ descriptor: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var offset = 0
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while offset < bytes.count, ContinuousClock().now < deadline {
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptorPoll, 1, 200) > 0 else { continue }
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            guard count > 0 else { return nil }
            offset += count
        }
        return offset == bytes.count ? bytes : nil
    }

    private func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            usleep(1_000)
        }
        return false
    }

    private final class TunnelCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var answeredPIDs: [pid_t] = []
        private var refusedCount = 0

        var answers: [pid_t] { lock.lock(); defer { lock.unlock() }; return answeredPIDs }
        var refusals: Int { lock.lock(); defer { lock.unlock() }; return refusedCount }

        func answered(_ pid: pid_t) { lock.lock(); answeredPIDs.append(pid); lock.unlock() }
        func refused() { lock.lock(); refusedCount += 1; lock.unlock() }
    }

    private final class AcceptScript: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Int32]
        private var callCount = 0

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        init(errors: [Int32]) {
            self.errors = errors
        }

        func accept(_ descriptor: Int32) -> SSHAskpassAcceptOutcome {
            lock.lock()
            callCount += 1
            let error = errors.isEmpty ? nil : errors.removeFirst()
            lock.unlock()
            return error.map(SSHAskpassAcceptOutcome.failed) ?? SSHAskpassBroker.systemAccept(descriptor)
        }
    }

    private final class PinMap: @unchecked Sendable {
        private let values: [[UInt8]: SSHAskpassProcessIdentity]

        init(_ values: [[UInt8]: SSHAskpassProcessIdentity]) {
            self.values = values
        }

        func value(for nonce: [UInt8]) -> SSHAskpassProcessIdentity? {
            values[nonce]
        }
    }

    private final class RevalidationState: @unchecked Sendable {
        private let lock = NSLock()
        private let invalidates: Bool
        private var callCount = 0

        init(invalidates: Bool) { self.invalidates = invalidates }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        var identityIsValid: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !invalidates || callCount < 2
        }

        func revalidate() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            return true
        }
    }

    private final class FakeStore: SSHSecretStore, @unchecked Sendable {
        let target: SSHTargetFingerprint
        private let lock = NSLock()
        private var fetchCount = 0

        var passwordFetches: Int {
            lock.lock()
            defer { lock.unlock() }
            return fetchCount
        }

        init(target: SSHTargetFingerprint) {
            self.target = target
        }

        func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer {
            lock.lock()
            fetchCount += 1
            lock.unlock()
            guard hostID == self.target.hostID, target == self.target else { throw SSHSecretStoreError.targetMismatch }
            let bytes: [UInt8] = [120]
            return bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) }
        }

        func target(for hostID: UUID) throws -> SSHTargetFingerprint {
            guard hostID == target.hostID else { throw SSHSecretStoreError.notFound }
            return target
        }

        func setPassword(_ secret: SSHSecretBuffer, for hostID: UUID, target: SSHTargetFingerprint, label: String) throws {}
        func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws {}
        func deletePassword(for hostID: UUID) throws {}
    }
}
