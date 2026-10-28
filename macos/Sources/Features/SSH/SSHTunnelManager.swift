import Darwin
import Foundation

/// Owns the app's tunnel ssh processes. Each one runs under the watchdog
/// script with a lifeline pipe on its standard input, so a tunnel never
/// outlives the app; the next launch's reaper handles anything left behind.
@MainActor
final class SSHTunnelManager: ObservableObject {
    struct Launch {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// Builds the watchdog launch for a definition. The URL is the pid file the
    /// watchdog writes the ssh process id into; a non-nil environment is the
    /// askpass environment of an interactive tunnel.
    typealias LaunchFactory = (SSHTunnelDefinition, URL, SSHLoginEnvironment, [String: String]?) throws -> Launch
    typealias ListenProbe = (pid_t, Int) -> Bool

    static let stderrLimit = 64 * 1024

    @Published private(set) var phases: [UUID: SSHTunnelPhase] = [:] {
        didSet {
            for (id, phase) in phases where oldValue[id] != phase {
                SSHLog.tunnel.notice(
                    "tunnel.phase id=\(id.uuidString, privacy: .public) phase=\(String(describing: phase), privacy: .public)")
            }
        }
    }
    /// Tunnels whose latest forwarded connection failed while the tunnel stayed up.
    @Published private(set) var channelFailures: Set<UUID> = []

    private final class Tunnel {
        let definition: SSHTunnelDefinition
        let pidFile: URL
        var process: Process?
        var lifeline: FileHandle?
        var errorReader: FileHandle?
        var stderr = Data()
        var ssh: SSHAskpassProcessIdentity?
        var stopRequested = false
        var exited = false
        var interactive = false
        /// When confirmation timing starts; reset after the user answers a prompt.
        var startedAt = ContinuousClock.now
        /// Set when authentication ended the tunnel; it outranks stderr.
        var failure: SSHTunnelFailure?
        /// This start's askpass session. A stale start can never revoke the
        /// session of a later start of the same tunnel.
        let authSession = UUID()

        init(definition: SSHTunnelDefinition, pidFile: URL) {
            self.definition = definition
            self.pidFile = pidFile
        }
    }

    private let runtimeRoot: URL
    private let login: () async -> SSHLoginEnvironment
    private let makeLaunch: LaunchFactory
    private let authentication: (any SSHTunnelAuthenticating)?
    private let isListening: ListenProbe
    private let remoteConfirmationDelay: Duration
    private let pollInterval: Duration
    private let stopGrace: Duration
    private var tunnels: [UUID: Tunnel] = [:]

    init(
        runtimeRoot: URL,
        login: @escaping () async -> SSHLoginEnvironment,
        makeLaunch: @escaping LaunchFactory,
        authentication: (any SSHTunnelAuthenticating)? = nil,
        isListening: @escaping ListenProbe = SSHTunnelManager.isListening,
        remoteConfirmationDelay: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(200),
        stopGrace: Duration = .seconds(5)
    ) {
        self.runtimeRoot = runtimeRoot
        self.login = login
        self.makeLaunch = makeLaunch
        self.authentication = authentication
        self.isListening = isListening
        self.remoteConfirmationDelay = remoteConfirmationDelay
        self.pollInterval = pollInterval
        self.stopGrace = stopGrace
    }

    convenience init(
        paths: SSHPaths,
        loginEnvironment: SSHLoginEnvironmentProvider,
        authentication: (any SSHTunnelAuthenticating)?
    ) {
        let watchdog = Bundle.main.url(forResource: "chostty-ssh-tunnel-watchdog", withExtension: "sh")
        self.init(
            runtimeRoot: paths.runtimeRoot,
            login: {
                await withCheckedContinuation { continuation in
                    loginEnvironment.value { continuation.resume(returning: $0) }
                }
            },
            makeLaunch: Self.watchdogLaunch(paths: paths, watchdog: watchdog),
            authentication: authentication)
    }

    // MARK: - State

    func phase(for id: UUID) -> SSHTunnelPhase {
        phases[id] ?? .stopped
    }

    func isRunning(_ id: UUID) -> Bool {
        tunnels[id] != nil
    }

    /// Tunnels counted by the toolbar badge: everything not stopped or stopping.
    var activeCount: Int {
        phases.values.filter { phase in
            switch phase {
            case .starting, .authenticating, .ready, .runningUnconfirmed: true
            case .stopped, .stopping, .failed: false
            }
        }.count
    }

    // MARK: - Start and stop

    func start(_ definition: SSHTunnelDefinition) {
        let id = definition.id
        guard tunnels[id] == nil else { return }
        let tunnel = Tunnel(
            definition: definition,
            pidFile: runtimeRoot.appendingPathComponent("\(id.uuidString).tunnel-pid"))
        tunnels[id] = tunnel
        channelFailures.remove(id)
        phases[id] = .starting
        let authentication = authentication
        Task { [weak self] in
            guard let self else { return }
            let environment = await self.login()
            let session = tunnel.authSession
            let preparation = await Task.detached {
                authentication?.prepare(definition, session: session) ?? .batch
            }.value
            guard self.tunnels[id] === tunnel, !tunnel.stopRequested else {
                authentication?.ended(session)
                return
            }
            switch preparation {
            case .failed(let message):
                self.fail(tunnel, .authentication(message))
            case .batch:
                self.launch(tunnel, environment: environment, askpass: nil)
            case .interactive(let askpass):
                self.launch(tunnel, environment: environment, askpass: askpass)
            }
        }
    }

    // MARK: - Authentication

    /// The tunnel running this authentication session. A session from an
    /// earlier start of the same tunnel matches nothing.
    private func running(session: UUID) -> Tunnel? {
        tunnels.values.first { $0.authSession == session }
    }

    /// ssh is waiting for the user, so the tunnel is not starting on its own.
    func beginAuthentication(session: UUID) {
        guard let tunnel = running(session: session), !tunnel.stopRequested else { return }
        let id = tunnel.definition.id
        guard phase(for: id) == .starting else { return }
        phases[id] = .authenticating
    }

    /// The user answered; confirmation timing starts again.
    func endAuthentication(session: UUID) {
        guard let tunnel = running(session: session) else { return }
        let id = tunnel.definition.id
        guard phase(for: id) == .authenticating else { return }
        tunnel.startedAt = .now
        phases[id] = .starting
    }

    /// No answer can come, so ssh is ended with this failure. The watchdog
    /// gets TERM too, and the usual grace period ends in SIGKILL.
    func failAuthentication(session: UUID, message: String) {
        guard let tunnel = running(session: session), !tunnel.stopRequested, tunnel.failure == nil else { return }
        let id = tunnel.definition.id
        tunnel.failure = .authentication(message)
        guard let process = tunnel.process else { return }
        if let ssh = currentSSH(tunnel) { kill(ssh.pid, SIGTERM) }
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        let grace = stopGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.tunnels[id] === tunnel else { return }
            self.forceKill(tunnel, watchdog: process)
        }
    }

    func stop(_ id: UUID) {
        guard let tunnel = tunnels[id], !tunnel.stopRequested else { return }
        tunnel.stopRequested = true
        guard let process = tunnel.process else {
            release(id)
            phases[id] = .stopped
            return
        }
        authentication?.ended(tunnel.authSession)
        phases[id] = .stopping
        // The watchdog stops ssh (TERM, then KILL) on lifeline EOF or on its own
        // TERM; the signal covers a lifeline a forked pane may have inherited.
        closeLifeline(tunnel)
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        let grace = stopGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.tunnels[id] === tunnel else { return }
            self.forceKill(tunnel, watchdog: process)
        }
    }

    /// Synchronous shutdown for app termination: SIGTERM, up to two seconds,
    /// then SIGKILL. No confirmation and no restart.
    @discardableResult
    func stopAll() -> Bool {
        stopNow(Array(tunnels.keys))
    }

    /// Stops the given tunnels before returning, with the same SIGTERM,
    /// two-second, SIGKILL sequence as app termination. Returns whether every
    /// verified ssh process is gone.
    func stopNow(_ ids: [UUID]) -> Bool {
        let active = ids.compactMap { tunnels[$0] }
        guard !active.isEmpty else { return true }
        for tunnel in active {
            tunnel.stopRequested = true
            closeLifeline(tunnel)
            if let process = tunnel.process, process.isRunning { kill(process.processIdentifier, SIGTERM) }
            if let ssh = currentSSH(tunnel) { kill(ssh.pid, SIGTERM) }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, active.contains(where: { currentSSH($0) != nil }) {
            usleep(50_000)
        }
        for tunnel in active {
            if let process = tunnel.process {
                forceKill(tunnel, watchdog: process)
            }
        }
        // SIGKILL is not instant; give the kernel a moment to retire ssh.
        let killDeadline = ContinuousClock.now + .milliseconds(500)
        while ContinuousClock.now < killDeadline, active.contains(where: { currentSSH($0) != nil }) {
            usleep(10_000)
        }
        let stopped = !active.contains { currentSSH($0) != nil }
        for tunnel in active {
            removeFiles(tunnel)
            closeErrors(tunnel)
            release(tunnel.definition.id)
            phases[tunnel.definition.id] = .stopped
        }
        return stopped
    }

    // MARK: - Process lifetime

    private func launch(_ tunnel: Tunnel, environment: SSHLoginEnvironment, askpass: [String: String]?) {
        let input = Pipe()
        let errors = Pipe()
        let descriptors = [
            input.fileHandleForReading.fileDescriptor,
            input.fileHandleForWriting.fileDescriptor,
            errors.fileHandleForReading.fileDescriptor,
            errors.fileHandleForWriting.fileDescriptor,
        ]
        guard descriptors.allSatisfy(Self.setCloseOnExec),
              Self.setNonBlocking(errors.fileHandleForReading.fileDescriptor)
        else {
            fail(tunnel, .exited(-1))
            return
        }

        let process = Process()
        do {
            let launch = try makeLaunch(tunnel.definition, tunnel.pidFile, environment, askpass)
            _ = unlink(tunnel.pidFile.path)
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.environment = launch.environment
            process.standardInput = input.fileHandleForReading
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors.fileHandleForWriting
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in
                    self?.finish(tunnel, status: status)
                }
            }
            try process.run()
        } catch {
            SSHLog.tunnel.error("SSH tunnel could not be started.")
            try? input.fileHandleForWriting.close()
            fail(tunnel, .exited(127))
            return
        }

        // Only the child keeps the read end of the lifeline and the write end
        // of stderr; the app holds the lifeline write end until it stops.
        try? input.fileHandleForReading.close()
        try? errors.fileHandleForWriting.close()
        tunnel.process = process
        tunnel.lifeline = input.fileHandleForWriting
        tunnel.errorReader = errors.fileHandleForReading
        tunnel.interactive = askpass != nil
        tunnel.startedAt = .now
        // ssh needs DNS, TCP and key exchange before its first prompt, so the
        // watchdog is still the process this turn just launched.
        if askpass != nil {
            let watchdog = SSHAskpassProcessIdentity.read(process.processIdentifier)
            if watchdog.flatMap({ authentication?.launched(tunnel.authSession, watchdog: $0) }) != true {
                failAuthentication(session: tunnel.authSession, message: SSHTunnelAskpassAuthorization.Message.unverified)
            }
        }

        Task { [weak self] in
            await self?.monitor(tunnel)
        }
    }

    private func monitor(_ tunnel: Tunnel) async {
        let id = tunnel.definition.id
        while tunnels[id] === tunnel, !tunnel.exited {
            drainErrors(tunnel)
            if tunnel.ssh == nil { tunnel.ssh = recordSSH(tunnel) }
            if case .starting = phase(for: id), !tunnel.stopRequested, let ssh = tunnel.ssh {
                switch tunnel.definition.kind {
                case .local, .dynamic:
                    if isListening(ssh.pid, tunnel.definition.bindPort) { settle(id, .ready) }
                case .remote:
                    // A rejected -R makes ssh exit (ExitOnForwardFailure); there
                    // is no positive signal, so it stays unconfirmed.
                    if ContinuousClock.now - tunnel.startedAt >= remoteConfirmationDelay {
                        settle(id, .runningUnconfirmed)
                    }
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func finish(_ tunnel: Tunnel, status: Int32) {
        let id = tunnel.definition.id
        tunnel.exited = true
        guard tunnels[id] === tunnel else { return }
        drainErrors(tunnel)
        closeErrors(tunnel)
        closeLifeline(tunnel)
        // A watchdog that died abnormally can leave its verified ssh behind.
        if let ssh = currentSSH(tunnel) { kill(ssh.pid, SIGKILL) }
        removeFiles(tunnel)
        release(id)
        if tunnel.stopRequested {
            phases[id] = .stopped
        } else {
            let text = Self.stderrText(tunnel.stderr)
            let failure = tunnel.failure ?? SSHTunnelStderrClassifier.classify(
                stderr: text, exitStatus: status, interactive: tunnel.interactive)
            phases[id] = .failed(failure)
            SSHLog.tunnel.error("SSH tunnel ended: \(failure.message, privacy: .public)")
        }
        tunnel.stderr = Data()
    }

    private func fail(_ tunnel: Tunnel, _ failure: SSHTunnelFailure) {
        let id = tunnel.definition.id
        guard tunnels[id] === tunnel else { return }
        release(id)
        phases[id] = tunnel.stopRequested ? .stopped : .failed(failure)
    }

    private func settle(_ id: UUID, _ phase: SSHTunnelPhase) {
        phases[id] = phase
        if let tunnel = tunnels[id] { authentication?.settled(tunnel.authSession) }
    }

    /// Forgets the tunnel and revokes its askpass token, closing any prompt.
    private func release(_ id: UUID) {
        guard let tunnel = tunnels.removeValue(forKey: id) else { return }
        authentication?.ended(tunnel.authSession)
    }

    /// Reads the pid the watchdog published and records it for the reaper
    /// only when the kernel confirms it is the watchdog's own child.
    private func recordSSH(_ tunnel: Tunnel) -> SSHAskpassProcessIdentity? {
        guard let process = tunnel.process,
              let text = try? String(contentsOf: tunnel.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let identity = SSHAskpassProcessIdentity.read(pid),
              identity.parentPID == process.processIdentifier,
              identity.realUID == getuid(),
              // Until the forked child execs ssh it still runs the watchdog's
              // shell; recording that path would make the reaper skip ssh.
              identity.executablePath
                != SSHAskpassProcessIdentity.read(process.processIdentifier)?.executablePath
        else { return nil }
        do {
            _ = try SSHTunnelReaper.writeRecord(for: tunnel.definition.id, sshPID: pid, in: runtimeRoot)
        } catch {
            SSHLog.tunnel.error("SSH tunnel reaper record could not be written.")
        }
        return identity
    }

    /// The recorded ssh process, if it is still the same kernel process.
    private func currentSSH(_ tunnel: Tunnel) -> SSHAskpassProcessIdentity? {
        if tunnel.ssh == nil { tunnel.ssh = recordSSH(tunnel) }
        guard let recorded = tunnel.ssh,
              let current = SSHAskpassProcessIdentity.read(recorded.pid),
              current.startSeconds == recorded.startSeconds,
              current.startMicroseconds == recorded.startMicroseconds,
              current.realUID == recorded.realUID
        else { return nil }
        return current
    }

    /// SIGKILLs the verified ssh; the watchdog then exits by itself and stops
    /// its helpers. Only when ssh was never identified are the watchdog's own
    /// children and the watchdog killed directly, so ssh is never orphaned.
    private func forceKill(_ tunnel: Tunnel, watchdog: Process) {
        if let ssh = currentSSH(tunnel) {
            kill(ssh.pid, SIGKILL)
        } else if tunnel.ssh == nil, watchdog.isRunning {
            let parent = watchdog.processIdentifier
            for child in Self.children(of: parent) { kill(child, SIGKILL) }
            kill(parent, SIGKILL)
        }
    }

    nonisolated private static func children(of parent: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { pid in
            pid > 1 && SSHAskpassProcessIdentity.read(pid)?.parentPID == parent
        }
    }

    // MARK: - Descriptors

    private func drainErrors(_ tunnel: Tunnel) {
        guard let descriptor = tunnel.errorReader?.fileDescriptor else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = false
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                tunnel.stderr.append(contentsOf: buffer[0..<count])
                received = true
            } else if count == 0 {
                closeErrors(tunnel)
                break
            } else if errno != EINTR {
                break
            }
        }
        guard received else { return }
        if tunnel.stderr.count > Self.stderrLimit {
            tunnel.stderr.removeFirst(tunnel.stderr.count - Self.stderrLimit)
        }
        if SSHTunnelStderrClassifier.containsChannelFailure(Self.stderrText(tunnel.stderr)) {
            channelFailures.insert(tunnel.definition.id)
        }
    }

    private func closeErrors(_ tunnel: Tunnel) {
        try? tunnel.errorReader?.close()
        tunnel.errorReader = nil
    }

    private func closeLifeline(_ tunnel: Tunnel) {
        try? tunnel.lifeline?.close()
        tunnel.lifeline = nil
    }

    /// Drops the tunnel's files. The reaper record stays while its verified ssh
    /// is still alive, so the next launch can still reclaim it.
    private func removeFiles(_ tunnel: Tunnel) {
        if currentSSH(tunnel) == nil {
            SSHTunnelReaper.removeRecord(for: tunnel.definition.id, in: runtimeRoot)
        }
        _ = unlink(tunnel.pidFile.path)
    }

    /// ssh diagnostics are ASCII; Latin-1 maps every byte, so a truncated or
    /// non-UTF-8 tail never hides a pattern.
    nonisolated static func stderrText(_ data: Data) -> String {
        String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    nonisolated static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    nonisolated private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    // MARK: - Defaults

    nonisolated static func watchdogLaunch(paths: SSHPaths, watchdog: URL?) -> LaunchFactory {
        { definition, pidFile, login, askpass in
            guard let watchdog else { throw CocoaError(.fileNoSuchFile) }
            let arguments = try SSHTunnelArguments.make(for: definition, paths: paths, interactive: askpass != nil)
            var environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !key.hasPrefix("SSH_ASKPASS") && !key.hasPrefix("CHOSTTY_SSH") && !key.hasPrefix("CHOSTTY_ASKPASS")
            }
            environment["PATH"] = login.path
            environment["SSH_AUTH_SOCK"] = login.authSocket
            environment.merge(askpass ?? [:]) { _, new in new }
            // The askpass helper only answers for /usr/bin/ssh, like panes.
            return Launch(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [watchdog.path, String(getpid()), pidFile.path, "--", "/usr/bin/ssh"] + arguments,
                environment: environment)
        }
    }

    /// Whether `pid` holds a TCP socket listening on `port`. The bind address is
    /// the one ssh was told to use, so the port on this process identifies it.
    nonisolated static func isListening(_ pid: pid_t, _ port: Int) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return false }
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP)
            else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if localPort == port { return true }
        }
        return false
    }
}
