import Darwin
import Foundation

/// How a tunnel's ssh may ask for anything.
enum SSHTunnelAuthPreparation: Equatable, Sendable {
    /// Prompts go to the broker; the values are the askpass environment.
    case interactive([String: String])
    /// No broker: `BatchMode=yes`, so ssh never prompts.
    case batch
    /// The tunnel must not start.
    case failed(String)
}

/// What the tunnel manager needs from authentication. Each start of a tunnel
/// has its own session, so a stale start never touches a later one.
protocol SSHTunnelAuthenticating: AnyObject, Sendable {
    /// Reads files; called off the main thread.
    func prepare(_ definition: SSHTunnelDefinition, session: UUID) -> SSHTunnelAuthPreparation
    /// Records the watchdog the app launched; false when it can't be verified.
    func launched(_ session: UUID, watchdog: SSHAskpassProcessIdentity) -> Bool
    func settled(_ session: UUID)
    func ended(_ session: UUID)
}

/// A prompt the app has to show for a tunnel.
struct SSHTunnelPromptRequest: Sendable {
    let id: UUID
    let tunnelID: UUID
    let host: SSHHostReference
    let prompt: SSHTunnelPrompt
}

/// The tunnel side of the askpass broker. A tunnel has no terminal, so the app
/// answers every prompt: a Keychain host's own password prompt from the
/// Keychain, everything else through a sheet. When no answer can come, the
/// tunnel's ssh is ended; the helper never writes an empty answer.
final class SSHTunnelAskpassAuthorization: SSHTunnelAuthenticating, @unchecked Sendable {
    enum Message {
        static let rejected = "Saved password was rejected."
        static let unavailable = "Saved password is unavailable for this tunnel."
        static let locked = "Saved password is locked."
        static let denied = "Saved password access was denied."
        static let notFound = "No saved password."
        static let brokerUnavailable = "Saved password broker is unavailable."
        static let cancelled = "Authentication was cancelled."
        static let timedOut = "Authentication timed out."
        static let unverified = "SSH asked for input Chostty couldn't verify."
        static let unsendable = "Saved password contains characters SSH can't receive."
        static let hostKeyConflict = "SSH reported a conflict with a known host key. Check it in a terminal tab."
    }

    private static let tokenLength = 32

    /// Shows a prompt. Each request is answered once through the closure.
    var present: (@Sendable (SSHTunnelPromptRequest, @escaping @Sendable (SSHSecretBuffer?) -> Void) -> Void)?
    /// Dismisses a prompt that is no longer wanted.
    var dismiss: (@Sendable (UUID) -> Void)?
    /// Whether a launch session is waiting for an answer from the user.
    var authenticating: (@Sendable (UUID, Bool) -> Void)?
    /// A launch session failed authentication; its ssh can never continue and
    /// is ended. Keyed by session so a late delivery never hits a restart.
    var failed: (@Sendable (UUID, String) -> Void)?

    private final class Waiter: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var reply: SSHSecretBuffer?
        var answered = false
    }

    private struct Session {
        let id: UUID
        let tunnelID: UUID
        let host: SSHHostReference
        let keychainHostID: UUID?
        let token: [UInt8]
        var launch: SSHAskpassTunnelLaunch?
        var passwordServed: Set<pid_t> = []
        var waiters: [UUID: Waiter] = [:]
        var notices: Set<UUID> = []
    }

    private let paths: SSHPaths
    private let secretStore: any SSHSecretStore
    private let appExecutablePath: String
    private let relayTimeout: DispatchTimeInterval
    private let lock = NSLock()
    /// Keyed by session, not by tunnel.
    private var sessions: [UUID: Session] = [:]
    private weak var broker: SSHAskpassBroker?

    init(
        paths: SSHPaths,
        secretStore: any SSHSecretStore,
        appExecutablePath: String,
        relayTimeout: DispatchTimeInterval = .seconds(110)
    ) {
        self.paths = paths
        self.secretStore = secretStore
        self.appExecutablePath = appExecutablePath
        self.relayTimeout = relayTimeout
    }

    var tunnelAuthority: SSHAskpassTunnelAuthority {
        SSHAskpassTunnelAuthority(
            launch: { [weak self] request in self?.launch(for: request) },
            answer: { [weak self] request, ssh in self?.answer(request, ssh: ssh) },
            refused: { [weak self] request in self?.refused(request) })
    }

    /// The broker serving `tunnelAuthority`; tunnels are batch-only without one.
    func attach(_ broker: SSHAskpassBroker?) {
        lock.lock()
        self.broker = broker
        lock.unlock()
    }

    private var socketURL: URL? {
        lock.lock()
        let broker = broker
        lock.unlock()
        guard let broker, broker.isAvailable else { return nil }
        return broker.socketURL
    }

    // MARK: - Tunnel lifetime

    func prepare(_ definition: SSHTunnelDefinition, session: UUID) -> SSHTunnelAuthPreparation {
        let keychainHostID = keychainHost(for: definition.host)
        guard let socket = socketURL else {
            return keychainHostID == nil ? .batch : .failed(Message.brokerUnavailable)
        }
        if let keychainHostID,
           SSHAskpassAuthorization.eligibleTarget(
               for: definition.host.alias, hostID: keychainHostID, paths: paths, secretStore: secretStore) == nil {
            return .failed(Message.unavailable)
        }
        guard let token = SSHAskpassAuthorization.secureRandomBytes(Self.tokenLength) else {
            return keychainHostID == nil ? .batch : .failed(Message.unavailable)
        }
        lock.lock()
        let previous = sessions.removeValue(forKey: session)
        sessions[session] = Session(
            id: session, tunnelID: definition.id, host: definition.host, keychainHostID: keychainHostID, token: token)
        lock.unlock()
        if let previous { cancel(previous) }
        return .interactive([
            "SSH_ASKPASS": appExecutablePath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
            "CHOSTTY_ASKPASS_SOCKET": socket.path,
            "CHOSTTY_ASKPASS_TOKEN": SSHAskpassAuthorization.hex(token),
            "CHOSTTY_ASKPASS_TUNNEL": "1",
        ])
    }

    /// Records the watchdog the app launched; prompts are refused before this.
    func launched(_ session: UUID, watchdog: SSHAskpassProcessIdentity) -> Bool {
        guard let owner = SSHAskpassProcessIdentity.read(getpid()) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard sessions[session] != nil else { return false }
        sessions[session]?.launch = SSHAskpassTunnelLaunch(watchdog: watchdog, owner: owner)
        return true
    }

    /// Whether a prompt still wants an answer. A dismissal can reach the main
    /// queue before the prompt it dismisses, so presenters check this.
    func isPending(_ requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.contains { $0.waiters[requestID] != nil || $0.notices.contains(requestID) }
    }

    /// The tunnel is up; any security-key notice is done.
    func settled(_ session: UUID) {
        lock.lock()
        let notices = sessions[session]?.notices ?? []
        sessions[session]?.notices = []
        lock.unlock()
        for notice in notices { dismiss?(notice) }
    }

    /// Revokes the token and drops every open prompt.
    func ended(_ session: UUID) {
        lock.lock()
        let removed = sessions.removeValue(forKey: session)
        lock.unlock()
        if let removed { cancel(removed) }
    }

    private func cancel(_ session: Session) {
        for (id, waiter) in session.waiters {
            signal(waiter, nil)
            dismiss?(id)
        }
        for notice in session.notices { dismiss?(notice) }
    }

    // MARK: - Broker callbacks

    private func launch(for request: SSHAskpassRequest) -> SSHAskpassTunnelLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return session(for: request)?.launch
    }

    private func refused(_ request: SSHAskpassRequest) {
        lock.lock()
        let id = session(for: request)?.id
        lock.unlock()
        if let id { failed?(id, Message.unverified) }
    }

    private func answer(_ request: SSHAskpassRequest, ssh: SSHAskpassProcessIdentity) -> SSHSecretBuffer? {
        lock.lock()
        guard let session = session(for: request), session.launch != nil else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        let prompt = SSHTunnelPrompt(prompt: request.prompt, mode: request.mode)
        if case .hostKey(let text) = prompt, SSHHostTrustSheetModel.reportsConflict(text) {
            _ = fail(session, Message.hostKeyConflict)
            return Array("no".utf8).withUnsafeBytes { SSHSecretBuffer(copying: $0) }
        }
        if let hostID = session.keychainHostID, case .input(let text) = prompt {
            guard let target = SSHAskpassAuthorization.eligibleTarget(
                for: session.host.alias, hostID: hostID, paths: paths, secretStore: secretStore)
            else {
                return fail(session, Message.unavailable)
            }
            if case .password = SSHAskpassPromptClassifier.classify(prompt: text, mode: nil, target: target) {
                return savedPassword(session, hostID: hostID, target: target, ssh: ssh)
            }
        }
        return relay(session, prompt: prompt)
    }

    private func savedPassword(
        _ session: Session, hostID: UUID, target: SSHTargetFingerprint, ssh: SSHAskpassProcessIdentity
    ) -> SSHSecretBuffer? {
        lock.lock()
        let first = sessions[session.id]?.passwordServed.insert(ssh.pid).inserted ?? false
        lock.unlock()
        guard first else { return fail(session, Message.rejected) }
        do {
            let password = try secretStore.password(for: hostID, matching: target)
            // The broker refuses these bytes; say why instead of "couldn't verify".
            let sendable = (1...1023).contains(password.count)
                && password.withUnsafeBytes { !$0.contains(0) && !$0.contains(10) && !$0.contains(13) }
            return sendable ? password : fail(session, Message.unsendable)
        } catch SSHSecretStoreError.locked {
            return fail(session, Message.locked)
        } catch SSHSecretStoreError.denied {
            return fail(session, Message.denied)
        } catch SSHSecretStoreError.notFound {
            return fail(session, Message.notFound)
        } catch {
            return fail(session, Message.unavailable)
        }
    }

    private func relay(_ session: Session, prompt: SSHTunnelPrompt) -> SSHSecretBuffer? {
        guard let present else { return fail(session, Message.unverified) }
        let request = SSHTunnelPromptRequest(
            id: UUID(), tunnelID: session.tunnelID, host: session.host, prompt: prompt)
        if case .notice = prompt {
            lock.lock()
            let live = sessions[session.id] != nil
            if live { sessions[session.id]?.notices.insert(request.id) }
            lock.unlock()
            if live { present(request) { $0?.wipe() } }
            return nil
        }

        let waiter = Waiter()
        lock.lock()
        guard sessions[session.id] != nil else {
            lock.unlock()
            return nil
        }
        sessions[session.id]?.waiters[request.id] = waiter
        lock.unlock()
        authenticating?(session.id, true)
        present(request) { [weak self] reply in
            if let self { self.signal(waiter, reply) } else { reply?.wipe() }
        }
        let timedOut = waiter.semaphore.wait(timeout: .now() + relayTimeout) == .timedOut
        lock.lock()
        let live = sessions[session.id]?.waiters.removeValue(forKey: request.id) != nil
        if timedOut { waiter.answered = true }
        let reply = waiter.reply
        waiter.reply = nil
        lock.unlock()
        authenticating?(session.id, false)
        if timedOut {
            reply?.wipe()
            dismiss?(request.id)
            return live ? fail(session, Message.timedOut) : nil
        }
        guard live else {
            reply?.wipe()
            return nil
        }
        guard let reply else { return fail(session, Message.cancelled) }
        return reply
    }

    private func signal(_ waiter: Waiter, _ reply: SSHSecretBuffer?) {
        lock.lock()
        guard !waiter.answered else {
            lock.unlock()
            reply?.wipe()
            return
        }
        waiter.answered = true
        waiter.reply = reply
        lock.unlock()
        waiter.semaphore.signal()
    }

    /// Reports a failure only while the session is live, so a revoked session
    /// never fails a later start of the same tunnel.
    private func fail(_ session: Session, _ message: String) -> SSHSecretBuffer? {
        lock.lock()
        let live = sessions[session.id] != nil
        lock.unlock()
        if live { failed?(session.id, message) }
        return nil
    }

    // MARK: - Lookup

    /// Caller holds the lock. Tokens are compared in constant time.
    private func session(for request: SSHAskpassRequest) -> Session? {
        guard request.nonce.count == Self.tokenLength else { return nil }
        return sessions.values.first { session in
            zip(session.token, request.nonce).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    private func keychainHost(for host: SSHHostReference) -> UUID? {
        guard case .managed(let hostID) = host.source,
              let metadata = try? SSHHostMetadataStore(paths: paths).load().metadata,
              metadata.hosts[hostID]?.auth == .keychain
        else { return nil }
        return hostID
    }
}
