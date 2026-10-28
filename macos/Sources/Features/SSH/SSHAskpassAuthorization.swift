import Dispatch
import Foundation
@preconcurrency import Security

/// Thread-safe, short-lived authority for one automatic-password SSH launch.
final class SSHAskpassAuthorization: @unchecked Sendable {
    private static let lifetime: Duration = .seconds(120)
    private static let tokenLength = 32
    private static let maximumTokenAttempts = 8

    private struct Pending: Equatable {
        let sequence: Int
        let identifier: UUID
        let createdAt: ContinuousClock.Instant
    }

    private struct Grant {
        let launchID: UUID
        let sequence: Int
        let token: [UInt8]
        let alias: String
        let target: SSHTargetFingerprint
        let supervisor: SSHAskpassProcessIdentity
        let expiresAt: ContinuousClock.Instant
        var reservationID: UUID?
        var reservedSSH: SSHAskpassProcessIdentity?
        var served = false
    }

    private let paths: SSHPaths
    private let secretStore: any SSHSecretStore
    private let warning: @Sendable (UUID, String?) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let randomBytes: @Sendable (Int) -> [UInt8]?
    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var grants: [UUID: Grant] = [:]

    convenience init(
        paths: SSHPaths,
        secretStore: any SSHSecretStore,
        warning: @escaping @Sendable (UUID, String?) -> Void
    ) {
        self.init(paths: paths, secretStore: secretStore, warning: warning,
                  now: { ContinuousClock().now }, randomBytes: { Self.secureRandomBytes($0) })
    }

    init(
        paths: SSHPaths,
        secretStore: any SSHSecretStore,
        warning: @escaping @Sendable (UUID, String?) -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        randomBytes: @escaping @Sendable (Int) -> [UInt8]?
    ) {
        self.paths = paths
        self.secretStore = secretStore
        self.warning = warning
        self.now = now
        self.randomBytes = randomBytes
    }

    var authority: SSHAskpassBrokerAuthority {
        SSHAskpassBrokerAuthority(
            supervisor: { [weak self] request in self?.supervisor(for: request) },
            reserve: { [weak self] request, supervisor in self?.reserve(request, supervisor: supervisor) },
            revalidate: { [weak self] reservation, request, ssh in
                self?.revalidate(reservation, request: request, ssh: ssh) ?? false
            },
            status: { [weak self] status in self?.record(status) })
    }

    func prepare(
        reference: SSHHostReference,
        launchID: UUID,
        sequence: Int,
        supervisor: SSHAskpassProcessIdentity?,
        brokerAvailable: Bool,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        let marker = Pending(sequence: sequence, identifier: UUID(), createdAt: now())
        lock.lock()
        cleanExpiredLocked(at: now())
        grants.removeValue(forKey: launchID)
        pending[launchID] = marker
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            let result = preflight(reference: reference, supervisor: supervisor, brokerAvailable: brokerAvailable)
            finish(launchID: launchID, marker: marker, result: result, completion: completion)
        }
    }

    func revoke(launchID: UUID) {
        lock.lock()
        grants.removeValue(forKey: launchID)
        pending.removeValue(forKey: launchID)
        lock.unlock()
    }

    func observed(launchID: UUID, sequence: Int) {
        lock.lock()
        if let grant = grants[launchID], sequence >= grant.sequence {
            grants.removeValue(forKey: launchID)
        }
        if let preparation = pending[launchID], sequence >= preparation.sequence {
            pending.removeValue(forKey: launchID)
        }
        lock.unlock()
    }

    private enum Preflight {
        case ready(hostID: UUID, alias: String, target: SSHTargetFingerprint, supervisor: SSHAskpassProcessIdentity)
        case manual(hostID: UUID?, warning: String?)
    }

    private func preflight(
        reference: SSHHostReference,
        supervisor: SSHAskpassProcessIdentity?,
        brokerAvailable: Bool
    ) -> Preflight {
        guard case let .managed(hostID) = reference.source else { return .manual(hostID: nil, warning: nil) }
        do {
            guard try SSHHostMetadataStore(paths: paths).load().metadata.hosts[hostID]?.auth == .keychain else {
                return .manual(hostID: nil, warning: nil)
            }
        } catch {
            return .manual(hostID: hostID, warning: "Saved password is unavailable.")
        }
        guard brokerAvailable, let supervisor else {
            return .manual(hostID: hostID, warning: "Saved password broker is unavailable.")
        }

        guard let target = eligibleTarget(for: reference.alias, hostID: hostID) else {
            return .manual(hostID: hostID, warning: "Saved password is unavailable for this SSH configuration.")
        }
        return .ready(hostID: hostID, alias: reference.alias, target: target, supervisor: supervisor)
    }

    private func eligibleTarget(for expectedAlias: String, hostID: UUID) -> SSHTargetFingerprint? {
        Self.eligibleTarget(for: expectedAlias, hostID: hostID, paths: paths, secretStore: secretStore)
    }

    /// Reads only attributes; password bytes are fetched exclusively by the broker after revalidation.
    static func eligibleTarget(
        for expectedAlias: String,
        hostID: UUID,
        paths: SSHPaths,
        secretStore: any SSHSecretStore
    ) -> SSHTargetFingerprint? {
        do {
            let contents = try SSHSecureFileWriter().read(at: paths.managedHostsFile)
            guard let data = contents.data else { return nil }
            let document = SSHConfigDocument(data: data)
            let blocks = document.managedBlocks.filter { $0.managedHostID == hostID }
            guard blocks.count == 1,
                  let host = try? document.managedHost(for: blocks[0]),
                  host.hostID == hostID,
                  host.alias.utf8.elementsEqual(expectedAlias.utf8),
                  let metadata = try SSHHostMetadataStore(paths: paths).load().metadata.hosts[hostID],
                  metadata.auth == .keychain,
                  case let .eligible(target) = SSHKeychainEligibility.evaluate(document: document, hostID: hostID)
            else {
                return nil
            }
            let storedTarget = try secretStore.target(for: hostID)
            guard storedTarget == target, storedTarget.serialized == target.serialized else { return nil }
            return target
        } catch {
            return nil
        }
    }

    private func finish(
        launchID: UUID,
        marker: Pending,
        result: Preflight,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        var issuedToken: String?
        var issuedWarning: (UUID, String?)?
        lock.lock()
        cleanExpiredLocked(at: now())
        guard pending[launchID] == marker else {
            lock.unlock()
            completion(nil)
            return
        }
        pending.removeValue(forKey: launchID)
        switch result {
        case let .manual(hostID, warning):
            if let hostID, let warning { issuedWarning = (hostID, warning) }
        case let .ready(hostID, alias, target, supervisor):
            guard let token = newTokenLocked() else {
                lock.unlock()
                warning(hostID, "Saved password is unavailable.")
                completion(nil)
                return
            }
            let expiry = now().advanced(by: Self.lifetime)
            grants[launchID] = Grant(launchID: launchID, sequence: marker.sequence, token: token, alias: alias,
                                     target: target, supervisor: supervisor, expiresAt: expiry,
                                     reservationID: nil, reservedSSH: nil)
            issuedToken = Self.hex(token)
        }
        lock.unlock()
        if let issuedWarning { warning(issuedWarning.0, issuedWarning.1) }
        completion(issuedToken)
    }

    private func supervisor(for request: SSHAskpassRequest) -> SSHAskpassProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        cleanExpiredLocked(at: now())
        return grants.values.first { $0.token == request.nonce }?.supervisor
    }

    private func reserve(
        _ request: SSHAskpassRequest,
        supervisor ssh: SSHAskpassProcessIdentity
    ) -> SSHAskpassReservation? {
        var rejectionWarning: UUID?
        let reservation: SSHAskpassReservation?
        lock.lock()
        cleanExpiredLocked(at: now())
        guard let launchID = grants.first(where: { $0.value.token == request.nonce })?.key,
              var grant = grants[launchID]
        else {
            lock.unlock()
            return nil
        }
        guard request.mode == nil,
              SSHAskpassPromptClassifier.classify(prompt: request.prompt, mode: request.mode, target: grant.target) == .password
        else {
            lock.unlock()
            return nil
        }
        guard grant.reservedSSH == nil else {
            if grant.served, grant.reservedSSH == ssh { rejectionWarning = grant.target.hostID }
            lock.unlock()
            if let rejectionWarning { warning(rejectionWarning, "Saved password was rejected.") }
            return nil
        }

        let identifier = UUID()
        grant.reservedSSH = ssh
        grant.reservationID = identifier
        grants[launchID] = grant
        reservation = SSHAskpassReservation(target: grant.target, expiresAt: grant.expiresAt, identifier: identifier)
        lock.unlock()
        return reservation
    }

    private func revalidate(
        _ reservation: SSHAskpassReservation,
        request: SSHAskpassRequest,
        ssh: SSHAskpassProcessIdentity
    ) -> Bool {
        let snapshot: Grant
        lock.lock()
        cleanExpiredLocked(at: now())
        guard let grant = grants.values.first(where: {
            $0.token == request.nonce && $0.reservationID == reservation.identifier && $0.reservedSSH == ssh &&
                $0.target == reservation.target && $0.expiresAt == reservation.expiresAt
        }) else {
            lock.unlock()
            return false
        }
        snapshot = grant
        lock.unlock()

        guard eligibleTarget(for: snapshot.alias, hostID: snapshot.target.hostID) == snapshot.target
        else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        cleanExpiredLocked(at: now())
        return grants.values.contains {
            $0.launchID == snapshot.launchID && $0.token == request.nonce && $0.sequence == snapshot.sequence &&
                $0.supervisor == snapshot.supervisor && $0.target == snapshot.target && $0.expiresAt == snapshot.expiresAt &&
                $0.reservationID == reservation.identifier && $0.reservedSSH == ssh
        }
    }

    private func record(_ status: SSHAskpassBrokerStatus) {
        var update: (UUID, String?)?
        lock.lock()
        cleanExpiredLocked(at: now())
        switch status {
        case .reserved:
            break
        case let .served(identifier):
            if let launchID = grants.first(where: { $0.value.reservationID == identifier })?.key,
               var grant = grants[launchID], grant.expiresAt > now() {
                grant.served = true
                grants[launchID] = grant
            }
        case let .rejected(identifier):
            if let identifier,
               let grant = grants.values.first(where: { $0.reservationID == identifier }) {
                update = (grant.target.hostID, "Saved password is unavailable.")
            }
        }
        lock.unlock()
        if let update { warning(update.0, update.1) }
    }

    private func cleanExpiredLocked(at instant: ContinuousClock.Instant) {
        grants = grants.filter { $0.value.expiresAt > instant }
        pending = pending.filter { $0.value.createdAt.advanced(by: Self.lifetime) > instant }
    }

    private func newTokenLocked() -> [UInt8]? {
        for _ in 0..<Self.maximumTokenAttempts {
            guard let token = randomBytes(Self.tokenLength), token.count == Self.tokenLength else { return nil }
            if !grants.values.contains(where: { $0.token == token }) { return token }
        }
        return nil
    }

    static func secureRandomBytes(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        return bytes
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789abcdef")
        var encoded = ""
        encoded.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0F)])
        }
        return encoded
    }
}
