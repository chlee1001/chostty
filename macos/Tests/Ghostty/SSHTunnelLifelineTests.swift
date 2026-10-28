import Darwin
import Foundation
import Testing
@testable import Ghostty

/// The watchdog contract: fake ssh ends within three seconds once the app is
/// gone, whether the lifeline closes or a leaked write end keeps it open.
@Suite(.serialized)
@MainActor
struct SSHTunnelLifelineTests {
    @Test func closingTheLifelineStopsSSH() async throws {
        try await withScratch { scratch in
            let input = Pipe()
            let process = try runWatchdog(scratch: scratch, fake: "exec /bin/sleep 30", stdin: input)
            let ssh = try #require(await waitForPID(scratch))

            try input.fileHandleForWriting.close()
            #expect(await waitFor(seconds: 3) { !processExists(ssh) })
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    @Test func sshExitingFirstReportsItsStatus() async throws {
        try await withScratch { scratch in
            let input = Pipe()
            let process = try runWatchdog(scratch: scratch, fake: "exit 7", stdin: input)
            process.waitUntilExit()
            #expect(process.terminationStatus == 7)
            try input.fileHandleForWriting.close()
        }
    }

    @Test func sshIgnoringTermIsKilledAfterTheGracePeriod() async throws {
        try await withScratch { scratch in
            let input = Pipe()
            let process = try runWatchdog(scratch: scratch, fake: "trap '' TERM; exec /bin/sleep 30", stdin: input)
            let ssh = try #require(await waitForPID(scratch))

            let closed = ContinuousClock.now
            try input.fileHandleForWriting.close()
            #expect(await waitFor(seconds: 4) { !processExists(ssh) })
            #expect(ContinuousClock.now - closed >= .milliseconds(1_500))
            process.waitUntilExit()
        }
    }

    @Test func anAppAlreadyGoneStartsNothing() async throws {
        try await withScratch { scratch in
            let input = Pipe()
            let process = try runWatchdog(
                scratch: scratch,
                fake: "exec /bin/sleep 30",
                stdin: input,
                owner: String(getpid() == 2 ? 3 : 2))
            process.waitUntilExit()
            #expect(process.terminationStatus == 75)
            #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("ssh.pid").path))
            try input.fileHandleForWriting.close()
        }
    }

    @Test func killedParentStopsSSH() async throws {
        try await withScratch { scratch in
            let ssh = try await killParent(scratch: scratch, leakToSleeper: false)
            #expect(await waitFor(seconds: 3) { !processExists(ssh) })
        }
    }

    // A long-lived process forked without a descriptor sweep
    // (as a libghostty pane can be inside the pipe()/FD_CLOEXEC window) holds
    // the lifeline write end, so EOF never arrives. Reparenting must still stop ssh.
    @Test func killedParentStopsSSHEvenWhenTheLifelineLeaked() async throws {
        try await withScratch { scratch in
            let ssh = try await killParent(scratch: scratch, leakToSleeper: true)
            defer { killSleeper(scratch) }
            #expect(await waitFor(seconds: 3) { !processExists(ssh) })
        }
    }
}

// MARK: - Fixtures

private func withScratch(_ body: (URL) async throws -> Void) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("chostty-lifeline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    try await body(scratch)
}

private func runWatchdog(scratch: URL, fake: String, stdin: Pipe, owner: String? = nil) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        try tunnelWatchdogURL().path, owner ?? String(getpid()), scratch.appendingPathComponent("ssh.pid").path,
        "--", "/bin/sh", "-c", fake,
    ]
    process.environment = ["PATH": "/usr/bin:/bin"]
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try stdin.fileHandleForReading.close()
    return process
}

@MainActor
private func waitForPID(_ scratch: URL) async -> pid_t? {
    let url = scratch.appendingPathComponent("ssh.pid")
    var pid: pid_t?
    _ = await waitFor(seconds: 3) {
        pid = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return pid != nil
    }
    return pid
}

/// An intermediate parent starts the watchdog on a FIFO lifeline it holds open,
/// optionally leaks that write end to a long-lived child, then is SIGKILLed.
@MainActor
private func killParent(scratch: URL, leakToSleeper: Bool) async throws -> pid_t {
    let fifo = scratch.appendingPathComponent("lifeline")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let sleeperFile = scratch.appendingPathComponent("sleeper.pid")
    let sleeper = leakToSleeper ? "/bin/sleep 30 & echo $! >\"$4\"; " : ""
    let middle = Process()
    middle.executableURL = URL(fileURLWithPath: "/bin/sh")
    middle.arguments = [
        "-c",
        "/bin/sh \"$1\" $$ \"$2\" -- /bin/sh -c 'exec /bin/sleep 30' <\"$3\" & exec 4>\"$3\"; \(sleeper)wait",
        "middle", try tunnelWatchdogURL().path, scratch.appendingPathComponent("ssh.pid").path, fifo.path,
        sleeperFile.path,
    ]
    middle.environment = ["PATH": "/usr/bin:/bin"]
    middle.standardInput = FileHandle.nullDevice
    middle.standardOutput = FileHandle.nullDevice
    middle.standardError = FileHandle.nullDevice
    try middle.run()
    let ssh = try #require(await waitForPID(scratch))
    if leakToSleeper {
        #expect(await waitFor(seconds: 3) { FileManager.default.fileExists(atPath: sleeperFile.path) })
    }
    kill(middle.processIdentifier, SIGKILL)
    middle.waitUntilExit()
    return ssh
}

/// Kills the leaked sleeper a regression test left holding the lifeline.
private func killSleeper(_ scratch: URL) {
    let url = scratch.appendingPathComponent("sleeper.pid")
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return }
    kill(pid, SIGKILL)
}
