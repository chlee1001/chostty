import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct SSHTunnelManagerTests {
    @Test func localTunnelIsReadyOnceFakeSSHListensAndStopsCleanly() async throws {
        try await withTunnelRoot { root in
            let port = try freePort()
            let manager = try makeManager(root: root, fake: "exec /usr/bin/nc -l 127.0.0.1 \(port)")
            let tunnel = definition(kind: .local, port: port)

            manager.start(tunnel)
            #expect(manager.phase(for: tunnel.id) == .starting)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .ready })
            #expect(manager.activeCount == 1)
            let record = root.appendingPathComponent("tunnels/\(tunnel.id.uuidString).json")
            #expect(FileManager.default.fileExists(atPath: record.path))
            let ssh = try #require(recordedPID(root: root, tunnel: tunnel))

            manager.stop(tunnel.id)
            #expect(manager.phase(for: tunnel.id) == .stopping)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
            #expect(manager.activeCount == 0)
            #expect(!FileManager.default.fileExists(atPath: record.path))
            #expect(await waitFor { !processExists(ssh) })
        }
    }

    @Test func remoteTunnelStaysUnconfirmedAfterTheDelay() async throws {
        try await withTunnelRoot { root in
            let manager = try makeManager(
                root: root,
                fake: "exec /bin/sleep 30",
                remoteDelay: .milliseconds(300))
            let tunnel = definition(kind: .remote, port: 9_000)

            manager.start(tunnel)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .runningUnconfirmed })
            #expect(manager.activeCount == 1)
            manager.stop(tunnel.id)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
        }
    }

    @Test func remoteTunnelIsNotConfirmedBeforeTheDelay() async throws {
        try await withTunnelRoot { root in
            let manager = try makeManager(root: root, fake: "exec /bin/sleep 30", remoteDelay: .seconds(30))
            let tunnel = definition(kind: .remote, port: 9_000)

            manager.start(tunnel)
            try await Task.sleep(for: .milliseconds(600))
            #expect(manager.phase(for: tunnel.id) == .starting)
            manager.stop(tunnel.id)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
        }
    }

    @Test func immediateExitIsClassifiedFromStderr() async throws {
        try await withTunnelRoot { root in
            let manager = try makeManager(
                root: root,
                fake: "echo 'bind [127.0.0.1]:5432: Address already in use' >&2; exit 255")
            let tunnel = definition(kind: .local, port: 5_432)

            manager.start(tunnel)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .failed(.localPortInUse) })
            #expect(manager.activeCount == 0)
            #expect(!manager.isRunning(tunnel.id))
        }
    }

    @Test func unclassifiedExitKeepsTheStatus() async throws {
        try await withTunnelRoot { root in
            let manager = try makeManager(root: root, fake: "exit 3")
            let tunnel = definition(kind: .dynamic, port: 1_080)

            manager.start(tunnel)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .failed(.exited(3)) })

            // The definition is untouched, so the same tunnel can start again.
            manager.start(tunnel)
            #expect(manager.phase(for: tunnel.id) == .starting)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .failed(.exited(3)) })
        }
    }

    @Test func stopKillsFakeSSHThatIgnoresTerm() async throws {
        try await withTunnelRoot { root in
            let manager = try makeManager(root: root, fake: "trap '' TERM; exec /bin/sleep 30")
            let tunnel = definition(kind: .local, port: try freePort())

            manager.start(tunnel)
            let ssh = try #require(await waitForValue { recordedPID(root: root, tunnel: tunnel) })
            manager.stop(tunnel.id)
            #expect(await waitFor(seconds: 6) { manager.phase(for: tunnel.id) == .stopped })
            #expect(await waitFor { !processExists(ssh) })
        }
    }

    @Test func channelFailureKeepsTheTunnelReady() async throws {
        try await withTunnelRoot { root in
            let port = try freePort()
            let manager = try makeManager(
                root: root,
                fake: "echo 'channel 2: open failed: connect failed: Connection refused' >&2; "
                    + "exec /usr/bin/nc -l 127.0.0.1 \(port)")
            let tunnel = definition(kind: .local, port: port)

            manager.start(tunnel)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .ready })
            #expect(await waitFor { manager.channelFailures.contains(tunnel.id) })
            #expect(manager.phase(for: tunnel.id) == .ready)
            manager.stop(tunnel.id)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
        }
    }

    @Test func stopAllEndsEveryTunnelSynchronously() async throws {
        try await withTunnelRoot { root in
            let manager = try makeManager(root: root, fake: "trap '' TERM; exec /bin/sleep 30")
            let first = definition(kind: .local, port: try freePort())
            let second = definition(kind: .dynamic, port: try freePort())
            manager.start(first)
            manager.start(second)
            let firstPID = try #require(await waitForValue { recordedPID(root: root, tunnel: first) })
            let secondPID = try #require(await waitForValue { recordedPID(root: root, tunnel: second) })

            let started = ContinuousClock.now
            manager.stopAll()
            #expect(ContinuousClock.now - started < .seconds(4))
            #expect(manager.phase(for: first.id) == .stopped)
            #expect(manager.phase(for: second.id) == .stopped)
            #expect(await waitFor { !processExists(firstPID) && !processExists(secondPID) })
            let records = (try? FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("tunnels").path)) ?? []
            #expect(records.isEmpty)
        }
    }

    @Test func fakeSSHHoldsNoInheritedDescriptors() async throws {
        try await withTunnelRoot { root in
            let report = root.appendingPathComponent("fds.txt")
            let manager = try makeManager(
                root: root,
                // Collect first: a redirected loop makes the shell park its own
                // stdout on fd 10, which the probe would then report.
                fake: "found=''; for fd in 3 4 5 6 7 8 9 10 11 12; do [ -e /dev/fd/$fd ] && found=\"$found$fd \"; done; "
                    + "printf '%s' \"$found\" >'\(report.path)'; exec /bin/sleep 30")
            let tunnel = definition(kind: .local, port: try freePort())

            manager.start(tunnel)
            #expect(await waitFor { FileManager.default.fileExists(atPath: report.path) })
            try await Task.sleep(for: .milliseconds(200))
            #expect(try String(contentsOf: report, encoding: .utf8) == "")
            manager.stop(tunnel.id)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
        }
    }

    @Test func aFailedPreparationNeverLaunches() async throws {
        try await withTunnelRoot { root in
            let auth = FakeAuthentication(.failed("Saved password is locked."))
            let launches = LaunchLog()
            let manager = try makeManager(root: root, fake: "exit 0", authentication: auth, launches: launches)
            let tunnel = definition(kind: .dynamic, port: try freePort())

            manager.start(tunnel)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .failed(.authentication("Saved password is locked.")) })
            #expect(launches.environments.isEmpty)
            #expect(auth.endedIDs == [tunnel.id])
        }
    }

    @Test func anInteractiveTunnelWaitsForAuthenticationAndEndsOnFailure() async throws {
        try await withTunnelRoot { root in
            let auth = FakeAuthentication(.interactive(["CHOSTTY_ASKPASS_TUNNEL": "1"]))
            let launches = LaunchLog()
            let manager = try makeManager(
                root: root,
                // Stderr that would classify as a refused key; the recorded failure wins.
                fake: "echo 'Host key verification failed.' >&2; trap 'exit 255' TERM; while :; do /bin/sleep 1; done",
                authentication: auth,
                launches: launches)
            let tunnel = definition(kind: .local, port: try freePort())

            manager.start(tunnel)
            let watchdog = try #require(await waitForValue { auth.watchdogs[tunnel.id] })
            #expect(watchdog.parentPID == getpid())
            #expect(launches.environments == [["CHOSTTY_ASKPASS_TUNNEL": "1"]])
            _ = try #require(await waitForValue { recordedPID(root: root, tunnel: tunnel) })

            let session = try #require(auth.launchedSessions.first)
            manager.beginAuthentication(session: UUID())
            #expect(manager.phase(for: tunnel.id) == .starting)
            manager.beginAuthentication(session: session)
            #expect(manager.phase(for: tunnel.id) == .authenticating)
            #expect(manager.activeCount == 1)
            manager.endAuthentication(session: session)
            #expect(manager.phase(for: tunnel.id) == .starting)

            manager.failAuthentication(session: session, message: "Authentication was cancelled.")
            #expect(await waitFor {
                manager.phase(for: tunnel.id) == .failed(.authentication("Authentication was cancelled."))
            })
            #expect(auth.endedIDs.contains(tunnel.id))
        }
    }

    @Test func aStaleStartNeverRevokesTheNextStartsSession() async throws {
        try await withTunnelRoot { root in
            let auth = FakeAuthentication(.interactive(["CHOSTTY_ASKPASS_TUNNEL": "1"]), firstPrepareDelay: 300_000)
            let manager = try makeManager(root: root, fake: "exec /bin/sleep 30", authentication: auth)
            let tunnel = definition(kind: .local, port: try freePort())

            manager.start(tunnel)
            #expect(await waitFor { auth.preparedSessions.count == 1 })
            manager.stop(tunnel.id)
            manager.start(tunnel)
            _ = try #require(await waitForValue { auth.watchdogs[tunnel.id] })
            let sessions = auth.preparedSessions
            #expect(sessions.count == 2)
            #expect(auth.launchedSessions == [sessions[1]])
            // The first start finishes late; only its own session is revoked.
            try await Task.sleep(for: .milliseconds(400))
            #expect(auth.endedSessions == [sessions[0]])
            // A late failure from the first start never reaches the second.
            manager.failAuthentication(session: sessions[0], message: "Authentication timed out.")
            manager.beginAuthentication(session: sessions[0])
            #expect(manager.phase(for: tunnel.id) == .starting)
            manager.stop(tunnel.id)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
            #expect(auth.endedSessions == sessions)
        }
    }

    @Test func aBatchTunnelGetsNoAskpassEnvironment() async throws {
        try await withTunnelRoot { root in
            let auth = FakeAuthentication(.batch)
            let launches = LaunchLog()
            let manager = try makeManager(root: root, fake: "exit 3", authentication: auth, launches: launches)
            let tunnel = definition(kind: .dynamic, port: try freePort())

            manager.start(tunnel)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .failed(.exited(3)) })
            #expect(launches.environments == [nil])
            #expect(auth.watchdogs.isEmpty)
        }
    }

    @Test func unrelatedChildrenDoNotInheritTheAppEnds() async throws {
        try await withTunnelRoot { root in
            // posix_spawn without CLOEXEC_DEFAULT inherits every descriptor that
            // is not close-on-exec, the way a libghostty pane fork+exec would.
            let count = "for fd in $(/bin/ls /dev/fd); do [ \"$fd\" -gt 2 ] && /usr/bin/stat -f '%HT' /dev/fd/$fd; done"
            let baseline = try spawnWithoutDescriptorSweep(count)
            let manager = try makeManager(root: root, fake: "exec /bin/sleep 30")
            let tunnel = definition(kind: .local, port: try freePort())
            manager.start(tunnel)
            _ = try #require(await waitForValue { recordedPID(root: root, tunnel: tunnel) })

            let during = try spawnWithoutDescriptorSweep(count)
            #expect(fifoCount(during) == fifoCount(baseline))

            // Control: an inheritable pipe is visible to the same probe.
            var leaked: [Int32] = [0, 0]
            #expect(pipe(&leaked) == 0)
            defer { leaked.forEach { close($0) } }
            #expect(fifoCount(try spawnWithoutDescriptorSweep(count)) == fifoCount(baseline) + 2)
            manager.stop(tunnel.id)
            #expect(await waitFor { manager.phase(for: tunnel.id) == .stopped })
        }
    }
}

// MARK: - Fixtures

@MainActor
private func makeManager(
    root: URL,
    fake: String,
    remoteDelay: Duration = .seconds(10),
    authentication: (any SSHTunnelAuthenticating)? = nil,
    launches: LaunchLog? = nil
) throws -> SSHTunnelManager {
    let watchdog = try tunnelWatchdogURL()
    return SSHTunnelManager(
        runtimeRoot: root,
        login: { SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil) },
        makeLaunch: { _, pidFile, login, askpass in
            launches?.record(askpass)
            return SSHTunnelManager.Launch(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [watchdog.path, String(getpid()), pidFile.path, "--", "/bin/sh", "-c", fake],
                environment: ["PATH": login.path])
        },
        authentication: authentication,
        remoteConfirmationDelay: remoteDelay,
        pollInterval: .milliseconds(50),
        stopGrace: .seconds(5))
}

private final class LaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: String]?] = []
    var environments: [[String: String]?] { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ environment: [String: String]?) { lock.lock(); stored.append(environment); lock.unlock() }
}

private final class FakeAuthentication: SSHTunnelAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let preparation: SSHTunnelAuthPreparation
    private let firstPrepareDelay: useconds_t
    private var prepared: [UUID: UUID] = [:]
    private var order: [UUID] = []
    private var recorded: [UUID: SSHAskpassProcessIdentity] = [:]
    private var launchedSession: [UUID] = []
    private var ended: [UUID] = []
    private var endedSession: [UUID] = []

    init(_ preparation: SSHTunnelAuthPreparation, firstPrepareDelay: useconds_t = 0) {
        self.preparation = preparation
        self.firstPrepareDelay = firstPrepareDelay
    }

    var watchdogs: [UUID: SSHAskpassProcessIdentity] { lock.lock(); defer { lock.unlock() }; return recorded }
    var endedIDs: [UUID] { lock.lock(); defer { lock.unlock() }; return ended }
    var preparedSessions: [UUID] { lock.lock(); defer { lock.unlock() }; return order }
    var launchedSessions: [UUID] { lock.lock(); defer { lock.unlock() }; return launchedSession }
    var endedSessions: [UUID] { lock.lock(); defer { lock.unlock() }; return endedSession }

    func prepare(_ definition: SSHTunnelDefinition, session: UUID) -> SSHTunnelAuthPreparation {
        lock.lock()
        let first = order.isEmpty
        prepared[session] = definition.id
        order.append(session)
        lock.unlock()
        if first, firstPrepareDelay > 0 { usleep(firstPrepareDelay) }
        return preparation
    }

    func launched(_ session: UUID, watchdog: SSHAskpassProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let tunnelID = prepared[session] else { return false }
        recorded[tunnelID] = watchdog
        launchedSession.append(session)
        return true
    }

    func settled(_ session: UUID) {}

    func ended(_ session: UUID) {
        lock.lock()
        if let tunnelID = prepared[session], !ended.contains(tunnelID) { ended.append(tunnelID) }
        if !endedSession.contains(session) { endedSession.append(session) }
        lock.unlock()
    }
}

func tunnelWatchdogURL() throws -> URL {
    try #require(Bundle.main.url(forResource: "chostty-ssh-tunnel-watchdog", withExtension: "sh"))
}

private func definition(kind: SSHTunnelDefinition.Kind, port: Int) -> SSHTunnelDefinition {
    SSHTunnelDefinition(
        id: UUID(),
        name: "fixture",
        host: SSHHostReference(source: .sshConfig, alias: "fixture"),
        kind: kind,
        bindPort: port,
        targetHost: kind == .dynamic ? nil : "127.0.0.1",
        targetPort: kind == .dynamic ? nil : 5_432)
}

private func withTunnelRoot(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("chostty-tunnel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func recordedPID(root: URL, tunnel: SSHTunnelDefinition) -> pid_t? {
    let url = root.appendingPathComponent("\(tunnel.id.uuidString).tunnel-pid")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func processExists(_ pid: pid_t) -> Bool {
    guard let info = SSHRuntimeRoot.processInfo(for: pid) else { return false }
    // A reaped-but-unwaited child is a zombie; it no longer runs.
    return info.pbi_status != UInt32(SZOMB)
}

private func freePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
        }
    }
    guard bound else { throw POSIXError(.EADDRINUSE) }
    return Int(UInt16(bigEndian: address.sin_port))
}

@MainActor
func waitFor(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

@MainActor
private func waitForValue<T>(seconds: Double = 5, _ value: () -> T?) async -> T? {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if let result = value() { return result }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return value()
}

private func fifoCount(_ output: String) -> Int {
    output.split(separator: "\n").filter { $0 == "Fifo File" || $0 == "Fifo" }.count
}

private func spawnWithoutDescriptorSweep(_ script: String) throws -> String {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("chostty-spawn-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }
    let arguments = ["/bin/sh", "-c", script + " >'\(output.path)' 2>/dev/null"]
    var argv = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ) == 0 else { throw POSIXError(.ECHILD) }
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
}
