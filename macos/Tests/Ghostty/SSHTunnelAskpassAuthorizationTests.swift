import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct SSHTunnelAskpassAuthorizationTests {
    @Test func withoutABrokerOnlyKeyTunnelsStart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization(broker: false)
        #expect(authorization.prepare(fixture.definition(managed: false), session: UUID()) == .batch)
        #expect(authorization.prepare(fixture.definition(managed: true), session: UUID())
                == .failed(SSHTunnelAskpassAuthorization.Message.brokerUnavailable))
    }

    @Test func anIneligibleKeychainHostFailsBeforeLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeManagedHost(hostName: "other.example.test")
        let authorization = fixture.authorization()
        #expect(authorization.prepare(fixture.definition(managed: true), session: UUID())
                == .failed(SSHTunnelAskpassAuthorization.Message.unavailable))
    }

    @Test func theTokenOnlyAnswersOnceTheWatchdogIsRecorded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let definition = fixture.definition(managed: false)
        let environment = try #require(fixture.environment(authorization.prepare(definition, session: definition.id)))
        #expect(environment["SSH_ASKPASS"] == fixture.app)
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment["CHOSTTY_ASKPASS_TUNNEL"] == "1")
        #expect(environment["CHOSTTY_ASKPASS_SOCKET"] != nil)
        let token = try #require(environment["CHOSTTY_ASKPASS_TOKEN"])
        #expect(token.count == 64)

        let authority = authorization.tunnelAuthority
        let request = fixture.request(token: token, prompt: "Password: ")
        #expect(authority.launch(request) == nil)
        #expect(authorization.launched(definition.id, watchdog: fixture.watchdog))
        let launch = try #require(authority.launch(request))
        #expect(launch.watchdog == fixture.watchdog)
        #expect(launch.owner.pid == getpid())
        #expect(authority.launch(fixture.request(token: String(repeating: "0", count: 64), prompt: "")) == nil)

        authorization.ended(definition.id)
        #expect(authority.launch(request) == nil)
    }

    @Test func aRelayedAnswerIsReturnedAndNeverStored() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let events = fixture.observe(authorization) { request, reply in
            #expect(request.prompt == .input("Verification code: "))
            reply(Fixture.buffer("424242"))
        }
        let (definition, token) = try fixture.launch(authorization, managed: false)

        let answer = authorization.tunnelAuthority.answer(
            fixture.request(token: token, prompt: "Verification code: "), fixture.ssh)
        #expect(answer.map(Fixture.string) == "424242")
        #expect(events.authenticating == [true, false])
        #expect(events.failures.isEmpty)
        #expect(fixture.store.passwordFetches == 0)
        authorization.ended(definition.id)
    }

    @Test func aHostKeyQuestionGetsTheTrustReply() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let question = "The authenticity of host 'db' can't be established.\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        let events = fixture.observe(authorization) { request, reply in
            #expect(request.prompt == .hostKey(question))
            reply(Fixture.buffer("no"))
        }
        let (_, token) = try fixture.launch(authorization, managed: false)
        let answer = authorization.tunnelAuthority.answer(fixture.request(token: token, prompt: question), fixture.ssh)
        #expect(answer.map(Fixture.string) == "no")
        #expect(events.failures.isEmpty)
    }

    @Test func aStaleStartCannotRevokeALaterStartOfTheSameTunnel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let definition = fixture.definition(managed: false)
        let stale = UUID()
        let current = UUID()
        _ = authorization.prepare(definition, session: stale)
        let environment = try #require(fixture.environment(authorization.prepare(definition, session: current)))
        let token = try #require(environment["CHOSTTY_ASKPASS_TOKEN"])
        #expect(authorization.launched(current, watchdog: fixture.watchdog))
        authorization.ended(stale)
        #expect(authorization.tunnelAuthority.launch(fixture.request(token: token, prompt: "")) != nil)
        authorization.ended(current)
        #expect(authorization.tunnelAuthority.launch(fixture.request(token: token, prompt: "")) == nil)
    }

    @Test func aHostKeyConflictIsRefusedWithoutAsking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let asked = Box<UUID>()
        let events = fixture.observe(authorization) { request, reply in
            asked.value = request.id
            reply(Fixture.buffer("yes"))
        }
        let (definition, token) = try fixture.launch(authorization, managed: false)
        let question = "The authenticity of host 'db (192.0.2.10)' can't be established\n"
            + "but keys of different type are already known for this host.\n"
            + "RSA key fingerprint is SHA256:abc.\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        let answer = authorization.tunnelAuthority.answer(fixture.request(token: token, prompt: question), fixture.ssh)
        #expect(answer.map(Fixture.string) == "no")
        #expect(asked.value == nil)
        #expect(events.failures == [definition.id: SSHTunnelAskpassAuthorization.Message.hostKeyConflict])
    }

    @Test func aCancelledPromptEndsTheTunnel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let events = fixture.observe(authorization) { _, reply in reply(nil) }
        let (definition, token) = try fixture.launch(authorization, managed: false)
        #expect(authorization.tunnelAuthority.answer(fixture.request(token: token, prompt: "Password: "), fixture.ssh) == nil)
        #expect(events.failures == [definition.id: SSHTunnelAskpassAuthorization.Message.cancelled])
    }

    @Test func anUnansweredPromptTimesOutAndIsDismissed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization(relayTimeout: .milliseconds(100))
        let shown = Box<UUID>()
        let events = fixture.observe(authorization) { request, _ in shown.value = request.id }
        let (definition, token) = try fixture.launch(authorization, managed: false)
        #expect(authorization.tunnelAuthority.answer(fixture.request(token: token, prompt: "Password: "), fixture.ssh) == nil)
        #expect(events.failures == [definition.id: SSHTunnelAskpassAuthorization.Message.timedOut])
        #expect(events.dismissed == [try #require(shown.value)])
    }

    @Test func stoppingTheTunnelDropsItsPromptWithoutAFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let (definition, token) = try fixture.launch(authorization, managed: false)
        let shown = Box<UUID>()
        let events = fixture.observe(authorization) { request, _ in
            shown.value = request.id
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
                authorization.ended(definition.id)
            }
        }
        #expect(authorization.tunnelAuthority.answer(fixture.request(token: token, prompt: "Password: "), fixture.ssh) == nil)
        #expect(events.failures.isEmpty)
        #expect(events.dismissed == [try #require(shown.value)])
    }

    @Test func aPromptStopsBeingPendingOnceItsTunnelEnds() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let (definition, token) = try fixture.launch(authorization, managed: false)
        let pending = Box<Bool>()
        let after = Box<Bool>()
        _ = fixture.observe(authorization) { request, reply in
            pending.value = authorization.isPending(request.id)
            authorization.ended(definition.id)
            after.value = authorization.isPending(request.id)
            reply(Fixture.buffer("late"))
        }
        #expect(authorization.tunnelAuthority.answer(fixture.request(token: token, prompt: "Password: "), fixture.ssh) == nil)
        #expect(pending.value == true)
        #expect(after.value == false)
        #expect(!authorization.isPending(UUID()))
    }

    @Test func aKeychainHostGetsItsPasswordOncePerSSHProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let events = fixture.observe(authorization) { _, reply in reply(Fixture.buffer("123456")) }
        let (definition, token) = try fixture.launch(authorization, managed: true)
        let authority = authorization.tunnelAuthority

        let password = authority.answer(fixture.request(token: token, prompt: fixture.passwordPrompt), fixture.ssh)
        #expect(password.map(Fixture.string) == "saved-secret")
        #expect(events.authenticating.isEmpty)
        // Other prompts of a Keychain host still go to the user.
        let code = authority.answer(fixture.request(token: token, prompt: "Verification code: "), fixture.ssh)
        #expect(code.map(Fixture.string) == "123456")
        #expect(authority.answer(fixture.request(token: token, prompt: fixture.passwordPrompt), fixture.ssh) == nil)
        #expect(events.failures == [definition.id: SSHTunnelAskpassAuthorization.Message.rejected])
        #expect(fixture.store.passwordFetches == 1)
    }

    @Test(arguments: [
        (SSHSecretStoreError.locked, SSHTunnelAskpassAuthorization.Message.locked),
        (.denied, SSHTunnelAskpassAuthorization.Message.denied),
        (.notFound, SSHTunnelAskpassAuthorization.Message.notFound),
        (.unexpected(-1), SSHTunnelAskpassAuthorization.Message.unavailable),
    ])
    func anUnavailableKeychainEndsTheTunnelWithItsReason(_ error: SSHSecretStoreError, _ message: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.store.error = error
        let authorization = fixture.authorization()
        let events = fixture.observe(authorization) { _, reply in reply(Fixture.buffer("never")) }
        let (definition, token) = try fixture.launch(authorization, managed: true)
        #expect(authorization.tunnelAuthority.answer(
            fixture.request(token: token, prompt: fixture.passwordPrompt), fixture.ssh) == nil)
        #expect(events.failures == [definition.id: message])
        #expect(events.authenticating.isEmpty)
    }

    @Test(arguments: ["line\nbreak", "carriage\rreturn", "nul\u{0}byte"])
    func aSavedPasswordSSHCannotReceiveEndsTheTunnelWithItsReason(_ secret: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.store.secret = secret
        let authorization = fixture.authorization()
        let events = fixture.observe(authorization) { _, reply in reply(Fixture.buffer("never")) }
        let (definition, token) = try fixture.launch(authorization, managed: true)
        #expect(authorization.tunnelAuthority.answer(
            fixture.request(token: token, prompt: fixture.passwordPrompt), fixture.ssh) == nil)
        #expect(events.failures == [definition.id: SSHTunnelAskpassAuthorization.Message.unsendable])
    }

    @Test func aRefusedRequestEndsTheTunnel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authorization = fixture.authorization()
        let events = fixture.observe(authorization) { _, reply in reply(nil) }
        let (definition, token) = try fixture.launch(authorization, managed: false)
        authorization.tunnelAuthority.refused(fixture.request(token: token, prompt: "Password: "))
        #expect(events.failures == [definition.id: SSHTunnelAskpassAuthorization.Message.unverified])
    }

    // MARK: - Fixture

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Bool] = []
        private var failed: [UUID: String] = [:]
        private var closed: [UUID] = []

        var authenticating: [Bool] { lock.lock(); defer { lock.unlock() }; return waits }
        var failures: [UUID: String] { lock.lock(); defer { lock.unlock() }; return failed }
        var dismissed: [UUID] { lock.lock(); defer { lock.unlock() }; return closed }

        func waiting(_ value: Bool) { lock.lock(); waits.append(value); lock.unlock() }
        func fail(_ id: UUID, _ message: String) { lock.lock(); failed[id] = failed[id] ?? message; lock.unlock() }
        func dismiss(_ id: UUID) { lock.lock(); closed.append(id); lock.unlock() }
    }

    final class FakeStore: SSHSecretStore, @unchecked Sendable {
        let target: SSHTargetFingerprint
        private let lock = NSLock()
        private var fetches = 0
        private var storedError: SSHSecretStoreError?
        private var storedSecret = "saved-secret"

        init(target: SSHTargetFingerprint) { self.target = target }

        var secret: String {
            get { lock.lock(); defer { lock.unlock() }; return storedSecret }
            set { lock.lock(); storedSecret = newValue; lock.unlock() }
        }

        var passwordFetches: Int { lock.lock(); defer { lock.unlock() }; return fetches }
        var error: SSHSecretStoreError? {
            get { lock.lock(); defer { lock.unlock() }; return storedError }
            set { lock.lock(); storedError = newValue; lock.unlock() }
        }

        func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer {
            lock.lock()
            fetches += 1
            let error = storedError
            let secret = storedSecret
            lock.unlock()
            if let error { throw error }
            guard target == self.target else { throw SSHSecretStoreError.targetMismatch }
            return Fixture.buffer(secret)
        }

        func target(for hostID: UUID) throws -> SSHTargetFingerprint {
            guard hostID == target.hostID else { throw SSHSecretStoreError.notFound }
            return target
        }

        func setPassword(_ secret: SSHSecretBuffer, for hostID: UUID, target: SSHTargetFingerprint, label: String) throws {}
        func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws {}
        func deletePassword(for hostID: UUID) throws {}
    }

    final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let hostID = UUID()
        let alias = "fixture"
        // The broker canonicalizes its app path, so it must exist.
        let app = "/bin/sh"
        let paths: SSHPaths
        let store: FakeStore
        let watchdog = SSHAskpassProcessIdentity(
            pid: 500, parentPID: getpid(), realUID: getuid(), effectiveUID: getuid(),
            startSeconds: 500, startMicroseconds: 1, ttyDevice: 0, executablePath: "/bin/bash")
        let ssh = SSHAskpassProcessIdentity(
            pid: 501, parentPID: 500, realUID: getuid(), effectiveUID: getuid(),
            startSeconds: 501, startMicroseconds: 1, ttyDevice: 0, executablePath: "/usr/bin/ssh")
        private var brokers: [SSHAskpassBroker] = []

        init() throws {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            paths = SSHPaths(home: root, runtimeRoot: root, environment: [:])
            store = FakeStore(target: try SSHTargetFingerprint(
                hostID: hostID, user: "alice", hostName: "example.test", port: 22))
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try writeManagedHost(hostName: "example.test")
            let metadata = try SSHHostMetadataFile(hosts: [hostID: try SSHManagedHostMetadata(auth: .keychain)])
            try JSONEncoder().encode(metadata).write(to: paths.metadataFile, options: .atomic)
        }

        var passwordPrompt: String { "alice@example.test's password: " }

        func authorization(
            broker: Bool = true,
            relayTimeout: DispatchTimeInterval = .seconds(5)
        ) -> SSHTunnelAskpassAuthorization {
            let authorization = SSHTunnelAskpassAuthorization(
                paths: paths, secretStore: store, appExecutablePath: app, relayTimeout: relayTimeout)
            if broker, let instance = try? SSHAskpassBroker(
                runtimeRoot: root, appProcessID: 777, appExecutablePath: app, secretStore: store,
                authority: SSHAskpassBrokerAuthority(
                    supervisor: { _ in nil }, reserve: { _, _ in nil },
                    revalidate: { _, _, _ in false }, status: { _ in }),
                tunnelAuthority: authorization.tunnelAuthority,
                inspect: { _ in nil }) {
                instance.start()
                brokers.append(instance)
                authorization.attach(instance)
            }
            return authorization
        }

        func observe(
            _ authorization: SSHTunnelAskpassAuthorization,
            present: @escaping @Sendable (SSHTunnelPromptRequest, @escaping @Sendable (SSHSecretBuffer?) -> Void) -> Void
        ) -> Events {
            let events = Events()
            authorization.present = present
            authorization.authenticating = { _, waiting in events.waiting(waiting) }
            authorization.failed = { id, message in events.fail(id, message) }
            authorization.dismiss = { id in events.dismiss(id) }
            return events
        }

        func launch(
            _ authorization: SSHTunnelAskpassAuthorization, managed: Bool
        ) throws -> (SSHTunnelDefinition, String) {
            let definition = definition(managed: managed)
            let environment = try #require(environment(authorization.prepare(definition, session: definition.id)))
            #expect(authorization.launched(definition.id, watchdog: watchdog))
            return (definition, try #require(environment["CHOSTTY_ASKPASS_TOKEN"]))
        }

        func definition(managed: Bool) -> SSHTunnelDefinition {
            SSHTunnelDefinition(
                id: UUID(),
                name: "fixture",
                host: SSHHostReference(source: managed ? .managed(hostID: hostID) : .sshConfig, alias: alias),
                kind: .dynamic,
                bindPort: 1080)
        }

        func environment(_ preparation: SSHTunnelAuthPreparation) -> [String: String]? {
            guard case .interactive(let environment) = preparation else { return nil }
            return environment
        }

        func request(token: String, prompt: String, mode: String? = nil) -> SSHAskpassRequest {
            let bytes = stride(from: 0, to: token.count, by: 2).compactMap { offset -> UInt8? in
                let start = token.index(token.startIndex, offsetBy: offset)
                return UInt8(token[start..<token.index(start, offsetBy: 2)], radix: 16)
            }
            return SSHAskpassRequest(nonce: bytes, mode: mode, prompt: prompt)
        }

        func writeManagedHost(hostName: String) throws {
            let text = "# chostty-host-id: \(hostID.uuidString)\nHost \(alias)\n  HostName \(hostName)\n  User alice\n  Port 22\n"
            try Data(text.utf8).write(to: paths.managedHostsFile, options: .atomic)
        }

        func remove() {
            brokers.forEach { $0.stop() }
            try? FileManager.default.removeItem(at: root)
        }

        static func buffer(_ text: String) -> SSHSecretBuffer {
            Array(text.utf8).withUnsafeBytes { SSHSecretBuffer(copying: $0) }
        }

        static func string(_ buffer: SSHSecretBuffer) -> String {
            buffer.withUnsafeBytes { String(bytes: $0, encoding: .utf8) ?? "" }
        }
    }
}
