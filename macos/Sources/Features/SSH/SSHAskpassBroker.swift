import Darwin
import Dispatch
import Foundation

struct SSHAskpassRequest: Sendable {
    let nonce: [UInt8]
    let mode: String?
    let prompt: String
}

struct SSHAskpassReservation: Sendable {
    let target: SSHTargetFingerprint
    let expiresAt: ContinuousClock.Instant
    let identifier: UUID
}

enum SSHAskpassBrokerStatus: Sendable, Equatable {
    case reserved(UUID)
    case served(UUID)
    case rejected(UUID?)
}

enum SSHAskpassAcceptOutcome: Sendable {
    case accepted(Int32)
    case failed(Int32)
}

/// The coordinator owns token issuance and revocation. A reservation is consumed by `reserve`,
/// even when this broker later rejects the request or Keychain access fails.
struct SSHAskpassBrokerAuthority: Sendable {
    let supervisor: @Sendable (SSHAskpassRequest) -> SSHAskpassProcessIdentity?
    let reserve: @Sendable (SSHAskpassRequest, SSHAskpassProcessIdentity) -> SSHAskpassReservation?
    let revalidate: @Sendable (SSHAskpassReservation, SSHAskpassRequest, SSHAskpassProcessIdentity) -> Bool
    let status: @Sendable (SSHAskpassBrokerStatus) -> Void
}

/// The two processes above a tunnel's ssh: the watchdog the app launched and the app itself.
struct SSHAskpassTunnelLaunch: Sendable, Equatable {
    let watchdog: SSHAskpassProcessIdentity
    let owner: SSHAskpassProcessIdentity
}

/// Tunnel tokens. A tunnel has no terminal, so the app answers every prompt:
/// a saved password or a reply relayed from a sheet.
struct SSHAskpassTunnelAuthority: Sendable {
    /// The launch a tunnel token belongs to, or nil for any other token.
    let launch: @Sendable (SSHAskpassRequest) -> SSHAskpassTunnelLaunch?
    /// Blocks until the app has an answer. nil sends none; when no answer can
    /// ever come, the authority has already asked the app to end that ssh.
    let answer: @Sendable (SSHAskpassRequest, SSHAskpassProcessIdentity) -> SSHSecretBuffer?
    /// A tunnel request failed verification; the app ends that ssh.
    let refused: @Sendable (SSHAskpassRequest) -> Void
}

final class SSHAskpassBroker: @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case listener
        case unsafeFallback
    }

    private enum Response: UInt8 { case denied = 0, secret = 1 }
    private static let maximumFrame = 8_192
    private static let maximumPrompt = 4_096
    private static let protocolVersion: UInt8 = 1
    private static let magic: [UInt8] = [0x43, 0x41, 0x50, 0x31] // CAP1

    let socketURL: URL
    private let listener: Int32
    private let socketDevice: dev_t
    private let socketInode: ino_t
    private let appExecutablePath: String
    private let secretStore: any SSHSecretStore
    private let authority: SSHAskpassBrokerAuthority
    private let tunnelAuthority: SSHAskpassTunnelAuthority?
    private let uid: uid_t
    private let inspect: SSHAskpassProcess.Inspector
    private let acceptClient: @Sendable (Int32) -> SSHAskpassAcceptOutcome
    private let lock = NSLock()
    private var activeClients = Set<Int32>()
    private var started = false
    private var stopped = false
    private var listenerClosed = false

    init(
        runtimeRoot: URL,
        appProcessID: pid_t = getpid(),
        appExecutablePath: String,
        secretStore: any SSHSecretStore,
        authority: SSHAskpassBrokerAuthority,
        tunnelAuthority: SSHAskpassTunnelAuthority? = nil,
        uid: uid_t = getuid(),
        inspect: @escaping SSHAskpassProcess.Inspector = SSHAskpassProcessIdentity.read,
        acceptClient: @escaping @Sendable (Int32) -> SSHAskpassAcceptOutcome = { SSHAskpassBroker.systemAccept($0) }
    ) throws {
        self.appExecutablePath = try Self.canonicalPath(appExecutablePath)
        self.secretStore = secretStore
        self.authority = authority
        self.tunnelAuthority = tunnelAuthority
        self.uid = uid
        self.inspect = inspect
        self.acceptClient = acceptClient
        let endpoint = try Self.makeListener(runtimeRoot: runtimeRoot, appProcessID: appProcessID, uid: uid)
        socketURL = endpoint.url
        listener = endpoint.descriptor
        socketDevice = endpoint.device
        socketInode = endpoint.inode
    }

    deinit { stop() }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !stopped && !listenerClosed
    }

    func start() {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { self.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if !listenerClosed {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
        }
        // This lock is shared with each worker's close. No copied descriptor number can be
        // shut down after the worker has closed it and the kernel has reused it.
        for client in activeClients { _ = Darwin.shutdown(client, SHUT_RDWR) }
        unlinkOwnSocketLocked()
        if !started {
            closeListenerLocked()
        }
        lock.unlock()
    }

    private func acceptLoop() {
        defer {
            lock.lock()
            closeListenerLocked()
            lock.unlock()
        }
        while true {
            let outcome = acceptClient(listener)
            guard case let .accepted(descriptor) = outcome else {
                guard case let .failed(error) = outcome else { continue }
                if shouldKeepAccepting(after: error) { continue }
                lock.lock()
                if !stopped {
                    failListenerLocked()
                }
                lock.unlock()
                return
            }
            var acceptedTime = timeval()
            guard gettimeofday(&acceptedTime, nil) == 0 else { _ = Darwin.close(descriptor); continue }
            let acceptedAt = (seconds: Int64(acceptedTime.tv_sec), microseconds: Int64(acceptedTime.tv_usec))
            // Darwin has no accept4; this fcntl follows accept and is the acknowledged race.
            guard Self.configure(descriptor) else { _ = Darwin.close(descriptor); continue }
            lock.lock()
            let shouldServe = !stopped && activeClients.count < 16
            if shouldServe { activeClients.insert(descriptor) }
            let shouldStop = stopped
            lock.unlock()
            guard shouldServe else {
                _ = Darwin.close(descriptor)
                if shouldStop { return }
                continue
            }
            DispatchQueue.global(qos: .utility).async { self.serve(descriptor, acceptedAt: acceptedAt) }
        }
    }

    private func shouldKeepAccepting(after error: Int32) -> Bool {
        if error == EINTR || error == EAGAIN || error == EWOULDBLOCK {
            return waitForListener()
        }
        if error == EMFILE || error == ENFILE || error == ENOBUFS || error == ECONNABORTED {
            usleep(10_000)
            lock.lock()
            let running = !stopped
            lock.unlock()
            return running
        }
        lock.lock()
        let running = !stopped
        lock.unlock()
        if running, error != EBADF, error != EINVAL, error != ENOTSOCK {
            usleep(10_000)
            return true
        }
        return false
    }

    private func serve(_ descriptor: Int32, acceptedAt: (seconds: Int64, microseconds: Int64)) {
        defer {
            lock.lock()
            activeClients.remove(descriptor)
            _ = Darwin.close(descriptor)
            lock.unlock()
        }
        var classification = "passthrough"
        var failure = "malformedRequest"
        defer {
            SSHLog.askpass.notice(
                "askpass.request classification=\(classification, privacy: .public) failure=\(failure, privacy: .public)")
        }
        guard let request = Self.readRequest(from: descriptor) else {
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        if let tunnelAuthority, let launch = tunnelAuthority.launch(request) {
            classification = "relay"
            failure = serveTunnel(descriptor, request: request, launch: launch, authority: tunnelAuthority,
                                  acceptedAt: acceptedAt)
            return
        }
        classification = request.mode == "none" ? "notify" : "passthrough"
        guard let initialSupervisor = authority.supervisor(request),
              let firstIdentity = validatedIdentity(
                  for: descriptor, supervisor: initialSupervisor, acceptedAt: acceptedAt)
        else {
            failure = "identity"
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        guard request.mode != "none", request.mode != "confirm" else {
            failure = "unsupportedMode"
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        guard let reservation = authority.reserve(request, firstIdentity.ssh) else {
            failure = "reservation"
            authority.status(.rejected(nil))
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        authority.status(.reserved(reservation.identifier))
        switch SSHAskpassPromptClassifier.classify(
            prompt: request.prompt,
            mode: request.mode,
            target: reservation.target
        ) {
        case .password: classification = "password"
        case .passthrough: classification = "passthrough"
        case .notify: classification = "notify"
        }
        guard classification == "password" else {
            failure = "classification"
            authority.status(.rejected(reservation.identifier))
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        guard reservation.expiresAt > ContinuousClock().now else {
            failure = "expired"
            authority.status(.rejected(reservation.identifier))
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        guard authority.revalidate(reservation, request, firstIdentity.ssh) else {
            failure = "revalidation"
            authority.status(.rejected(reservation.identifier))
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        let secret: SSHSecretBuffer
        do {
            secret = try secretStore.password(for: reservation.target.hostID, matching: reservation.target)
        } catch {
            failure = "secretUnavailable"
            authority.status(.rejected(reservation.identifier))
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        defer { secret.wipe() }
        guard Self.isSecret(secret),
              authority.revalidate(reservation, request, firstIdentity.ssh),
              Self.connectionIsLive(descriptor),
              let finalSupervisor = authority.supervisor(request),
              finalSupervisor == initialSupervisor,
              let finalIdentity = validatedIdentity(
                  for: descriptor, supervisor: finalSupervisor, acceptedAt: acceptedAt),
              finalIdentity == firstIdentity,
              reservation.expiresAt > ContinuousClock().now
        else {
            failure = "finalValidation"
            authority.status(.rejected(reservation.identifier))
            Self.writeResponse(.denied, to: descriptor)
            return
        }
        guard Self.writeSecret(secret, to: descriptor) else {
            failure = "writeFailed"
            authority.status(.rejected(reservation.identifier))
            return
        }
        authority.status(.served(reservation.identifier))
        failure = "none"
    }

    /// The tunnel path has no reservation step: the authority answers or
    /// declines, and the peer chain is checked again before any byte is sent.
    private func serveTunnel(
        _ descriptor: Int32, request: SSHAskpassRequest, launch: SSHAskpassTunnelLaunch,
        authority: SSHAskpassTunnelAuthority, acceptedAt: (seconds: Int64, microseconds: Int64)
    ) -> String {
        guard let first = validatedTunnelIdentity(for: descriptor, launch: launch, acceptedAt: acceptedAt) else {
            authority.refused(request)
            Self.writeResponse(.denied, to: descriptor)
            return "identity"
        }
        guard let secret = authority.answer(request, first.ssh) else {
            Self.writeResponse(.denied, to: descriptor)
            return "noAnswer"
        }
        defer { secret.wipe() }
        guard Self.isSecret(secret),
              Self.connectionIsLive(descriptor),
              authority.launch(request) == launch,
              validatedTunnelIdentity(for: descriptor, launch: launch, acceptedAt: acceptedAt) == first
        else {
            authority.refused(request)
            Self.writeResponse(.denied, to: descriptor)
            return "finalValidation"
        }
        guard Self.writeSecret(secret, to: descriptor) else {
            authority.refused(request)
            return "writeFailed"
        }
        return "none"
    }

    private func validatedTunnelIdentity(
        for descriptor: Int32, launch: SSHAskpassTunnelLaunch,
        acceptedAt: (seconds: Int64, microseconds: Int64)
    ) -> PeerIdentity? {
        guard let peerUID = Self.peerUID(descriptor), peerUID == uid,
              let peerPID = Self.peerPID(descriptor),
              let chain = SSHAskpassProcess.chain(from: peerPID, inspect: inspect),
              (chain[0].startSeconds, chain[0].startMicroseconds) <= (acceptedAt.seconds, acceptedAt.microseconds),
              SSHAskpassProcess.validatesTunnel(chain: chain, peerUID: peerUID, watchdog: launch.watchdog,
                                                owner: launch.owner, appExecutablePath: appExecutablePath, uid: uid)
        else { return nil }
        return PeerIdentity(peer: chain[0], ssh: chain[1])
    }

    private func validatedIdentity(
        for descriptor: Int32, supervisor: SSHAskpassProcessIdentity,
        acceptedAt: (seconds: Int64, microseconds: Int64)
    ) -> PeerIdentity? {
        guard let peerUID = Self.peerUID(descriptor), peerUID == uid,
              let peerPID = Self.peerPID(descriptor),
              let chain = SSHAskpassProcess.chain(from: peerPID, inspect: inspect),
              (chain[0].startSeconds, chain[0].startMicroseconds) <= (acceptedAt.seconds, acceptedAt.microseconds),
              SSHAskpassProcess.validates(chain: chain, peerUID: peerUID, supervisor: supervisor,
                                          appExecutablePath: appExecutablePath, uid: uid)
        else { return nil }
        return PeerIdentity(peer: chain[0], ssh: chain[1])
    }

    private func waitForListener() -> Bool {
        lock.lock()
        let shouldContinue = !stopped
        lock.unlock()
        guard shouldContinue else { return false }
        var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        _ = poll(&poller, 1, 1_000)
        lock.lock()
        let stillRunning = !stopped
        lock.unlock()
        return stillRunning
    }

    private func closeListenerLocked() {
        guard !listenerClosed else { return }
        listenerClosed = true
        _ = Darwin.close(listener)
    }

    private func failListenerLocked() {
        stopped = true
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        for client in activeClients { _ = Darwin.shutdown(client, SHUT_RDWR) }
        unlinkOwnSocketLocked()
        closeListenerLocked()
    }

    private func unlinkOwnSocketLocked() {
        var info = stat()
        if lstat(socketURL.path, &info) == 0, info.st_dev == socketDevice, info.st_ino == socketInode {
            _ = unlink(socketURL.path)
        }
    }

    private struct PeerIdentity: Equatable {
        let peer: SSHAskpassProcessIdentity
        let ssh: SSHAskpassProcessIdentity
    }

    private struct ListenerEndpoint {
        let url: URL
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
    }

    private static func makeListener(runtimeRoot: URL, appProcessID: pid_t, uid: uid_t)
        throws -> ListenerEndpoint {
        let normal = runtimeRoot.appendingPathComponent("askpass", isDirectory: true)
            .appendingPathComponent("broker.sock")
        let url: URL
        if normal.path.utf8.count + 1 <= 104 {
            try FileManager.default.createDirectory(at: normal.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            url = normal
        } else {
            let parent = URL(fileURLWithPath: try canonicalPath("/tmp"), isDirectory: true)
            try validateParent(parent, uid: uid)
            let directory = parent.appendingPathComponent("chostty-\(uid)", isDirectory: true)
            try prepareFallbackDirectory(directory, uid: uid)
            url = directory.appendingPathComponent("broker-\(appProcessID).sock")
        }
        guard let address = unixAddress(url.path) else { throw Error.listener }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, configure(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw Error.listener
        }
        var existing = stat()
        guard lstat(url.path, &existing) != 0, errno == ENOENT else {
            _ = Darwin.close(descriptor)
            throw Error.listener
        }
        let bound = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            _ = Darwin.close(descriptor)
            throw Error.listener
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            _ = Darwin.close(descriptor)
            throw Error.listener
        }
        guard chmod(url.path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            _ = Darwin.close(descriptor)
            unlinkOwnSocket(url, device: info.st_dev, inode: info.st_ino)
            throw Error.listener
        }
        return ListenerEndpoint(url: url, descriptor: descriptor, device: info.st_dev, inode: info.st_ino)
    }

    static func systemAccept(_ descriptor: Int32) -> SSHAskpassAcceptOutcome {
        let accepted = Darwin.accept(descriptor, nil, nil)
        return accepted >= 0 ? .accepted(accepted) : .failed(errno)
    }

    static func prepareFallbackDirectory(_ url: URL, uid: uid_t = getuid()) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw Error.unsafeFallback }
        var link = stat()
        guard lstat(url.path, &link) == 0, link.st_mode & S_IFMT == S_IFDIR, link.st_uid == uid,
              link.st_mode & 0o7777 == 0o700
        else { throw Error.unsafeFallback }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.unsafeFallback }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == link.st_dev, info.st_ino == link.st_ino,
              info.st_uid == uid, info.st_mode & 0o7777 == 0o700
        else { throw Error.unsafeFallback }
    }

    private static func validateParent(_ url: URL, uid: uid_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Error.unsafeFallback }
        let mode = info.st_mode & 0o7777
        guard (info.st_uid == 0 && mode & S_ISVTX != 0) || (info.st_uid == uid && mode == 0o700) else {
            throw Error.unsafeFallback
        }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw Error.listener }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func unlinkOwnSocket(_ url: URL, device: dev_t, inode: ino_t) {
        var current = stat()
        if lstat(url.path, &current) == 0, current.st_dev == device, current.st_ino == inode {
            _ = unlink(url.path)
        }
    }

    private static func unixAddress(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count + 1 <= 104 else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address) { raw in
            bytes.withUnsafeBytes { source in
                raw.baseAddress!.advanced(by: 2).copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        return address
    }

    private static func configure(_ descriptor: Int32) -> Bool {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard descriptorFlags >= 0, statusFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
        else { return false }
        var enabled: Int32 = 1
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func readRequest(from descriptor: Int32) -> SSHAskpassRequest? {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        guard let prefix = readExact(descriptor, count: 4, deadline: deadline),
              let length = decodeUInt32(prefix), length <= maximumFrame,
              let frame = readExact(descriptor, count: Int(length), deadline: deadline)
        else { return nil }
        return decodeRequest(frame)
    }

    static func decodeRequest(_ frame: [UInt8]) -> SSHAskpassRequest? {
        guard frame.count >= 4 + 1 + 32 + 1 + 2,
              Array(frame[0..<4]) == magic, frame[4] == protocolVersion else { return nil }
        let nonce = Array(frame[5..<37])
        let modeLength = Int(frame[37])
        let promptLengthOffset = 38 + modeLength
        guard modeLength <= 32, promptLengthOffset + 2 <= frame.count,
              let promptLength = decodeUInt16(Array(frame[promptLengthOffset..<(promptLengthOffset + 2)])),
              promptLength <= maximumPrompt, promptLengthOffset + 2 + Int(promptLength) == frame.count,
              let prompt = String(bytes: frame[(promptLengthOffset + 2)...], encoding: .utf8)
        else { return nil }
        let modeBytes = frame[38..<promptLengthOffset]
        guard let mode = String(bytes: modeBytes, encoding: .utf8), !mode.utf8.contains(0) else { return nil }
        return SSHAskpassRequest(nonce: nonce, mode: mode.isEmpty ? nil : mode, prompt: prompt)
    }

    static func encodeRequest(nonce: [UInt8], mode: String?, prompt: [UInt8]) -> [UInt8]? {
        let modeBytes = Array((mode ?? "").utf8)
        guard nonce.count == 32, modeBytes.count <= 32, prompt.count <= maximumPrompt,
              !prompt.contains(0), let length = UInt16(exactly: prompt.count) else { return nil }
        var frame = magic + [protocolVersion] + nonce + [UInt8(modeBytes.count)] + modeBytes
        frame += encodeUInt16(length) + prompt
        return encodeUInt32(UInt32(frame.count)) + frame
    }

    private static func peerUID(_ descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    private static func peerPID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, size == MemoryLayout<pid_t>.size,
              pid > 1 else { return nil }
        return pid
    }

    private static func connectionIsLive(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count != 0 && (count > 0 || errno == EAGAIN || errno == EWOULDBLOCK)
    }

    private static func isSecret(_ secret: SSHSecretBuffer) -> Bool {
        guard (1...1023).contains(secret.count) else { return false }
        return secret.withUnsafeBytes { !$0.contains(0) && !$0.contains(10) && !$0.contains(13) }
    }

    private static func writeResponse(_ response: Response, to descriptor: Int32) {
        _ = writeAll(
            descriptor,
            bytes: magic + [protocolVersion, response.rawValue, 0, 0],
            deadline: ContinuousClock().now.advanced(by: .seconds(5)))
    }

    private static func writeSecret(_ secret: SSHSecretBuffer, to descriptor: Int32) -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(120))
        guard let length = UInt16(exactly: secret.count),
              writeAll(
                  descriptor,
                  bytes: magic + [protocolVersion, Response.secret.rawValue] + encodeUInt16(length),
                  deadline: deadline)
        else { return false }
        return secret.withUnsafeBytes {
            writeAll(descriptor, pointer: $0.baseAddress!, count: $0.count, deadline: deadline)
        }
    }

    private static func readExact(
        _ descriptor: Int32, count: Int, deadline: ContinuousClock.Instant
    ) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            var waiter = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard let timeout = pollTimeout(until: deadline), poll(&waiter, 1, timeout) > 0 else { return nil }
            let read = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if read == 0 { return nil }
            if read < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return nil
            }
            offset += read
        }
        return bytes
    }

    private static func writeAll(
        _ descriptor: Int32, bytes: [UInt8], deadline: ContinuousClock.Instant
    ) -> Bool {
        bytes.withUnsafeBytes { writeAll(descriptor, pointer: $0.baseAddress!, count: $0.count, deadline: deadline) }
    }

    private static func writeAll(
        _ descriptor: Int32, pointer: UnsafeRawPointer, count: Int, deadline: ContinuousClock.Instant
    ) -> Bool {
        var offset = 0
        while offset < count {
            var waiter = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard let timeout = pollTimeout(until: deadline), poll(&waiter, 1, timeout) > 0 else { return false }
            let written = Darwin.write(descriptor, pointer.advanced(by: offset), count - offset)
            if written < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return false
            }
            if written == 0 { return false }
            offset += written
        }
        return true
    }

    private static func pollTimeout(until deadline: ContinuousClock.Instant) -> Int32? {
        let duration = ContinuousClock().now.duration(to: deadline)
        guard duration > .zero else { return nil }
        let components = duration.components
        guard components.seconds < Int64(Int32.max) / 1_000 else { return Int32.max }
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return Int32(clamping: max(milliseconds, 1))
    }

    private static func decodeUInt16(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private static func decodeUInt32(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func encodeUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    private static func encodeUInt32(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
}
