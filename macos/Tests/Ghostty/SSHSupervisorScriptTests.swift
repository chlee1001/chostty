import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHSupervisorScriptTests {
    @Test func parsesOnlyCompleteStateLines() {
        #expect(SSHPaneStateFile.parse("waiting 0\n") == .waiting(sequence: 0))
        #expect(SSHPaneStateFile.parse("connected 9") == .connected(sequence: 9))
        #expect(SSHPaneStateFile.parse("exited 2 255 1") == .exited(sequence: 2, status: 255, everConnected: true))
        #expect(SSHPaneStateFile.parse("connected -1") == nil)
        #expect(SSHPaneStateFile.parse("exited 1 nope 1") == nil)
        #expect(SSHPaneStateFile.parse("") == nil)
        #expect(SSHPaneStateFile.parse("unknown 1") == nil)
        #expect(SSHPaneStateFile.parse("connected 999999999999999999999999") == nil)
    }

    @Test func describesPTYOutputWithoutLosingInvalidBytes() {
        #expect(SupervisorFixture.describePTYOutput(Data([0xff, 0x41])) == "Non-UTF-8 PTY bytes: \\xFF\\x41")
        #expect(SupervisorFixture.describePTYOutput(Data("한글".utf8)) == "한글")
    }

    @Test func authenticatesInCanonicalModeThenReportsConnectedAndExits() throws {
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            stty -a | grep -q -- '-icanon' && exit 88
            printf 'AUTHENTICATING-CANONICAL\\n'
            IFS= read -r _
            stty -icanon -isig min 1 time 0
            stty -a | grep -q -- '-icanon' || exit 89
            printf 'RAW\\n'
            sleep 1
            exit 0
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connecting(sequence: 1))
        try fixture.waitForOutput("AUTHENTICATING-CANONICAL")

        fixture.writeToTerminal("continue\n")
        try fixture.waitForState(.connected(sequence: 1))
        try fixture.waitForOutput("RAW")

        try fixture.waitForState(.exited(sequence: 1, status: 0, everConnected: true))
        #expect(try fixture.waitForExit() == 0)
    }

    @Test func failedConnectionStaysOpenUntilReturnAndResetsTheTerminal() throws {
        let marker = "FAKE-SSH-EXIT"
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            stty -icanon -isig min 1 time 0
            sleep 1
            printf '\(marker)\\n'
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connecting(sequence: 1))
        try fixture.waitForState(.connected(sequence: 1))
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: true))
        try fixture.waitForOutput("press Return to reconnect")

        #expect(fixture.isAlive)
        let output = fixture.output
        let markerEnd = try #require(output.range(of: marker)?.upperBound)
        let following = output[markerEnd...]
        let firstEscape = try #require(following.firstIndex(of: "\u{1B}"))
        #expect(following[firstEscape...].hasPrefix("\u{1B}7\u{1B}[?1049l"))

        fixture.writeToTerminal("\r")
        try fixture.waitForState(.connectRequested(sequence: 1))
    }

    @Test func authenticationRawModeWithSignalsStaysConnectingUntilSSHRawMode() throws {
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            stty -icanon isig min 1 time 0
            printf 'AUTH-RAW-SIGNALS\\n'
            sleep 1
            stty -isig
            printf 'SSH-RAW\\n'
            sleep 1
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connecting(sequence: 1))
        try fixture.waitForOutput("AUTH-RAW-SIGNALS")
        usleep(500_000)
        #expect(fixture.currentState == .connecting(sequence: 1))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("ever").path))

        try fixture.waitForOutput("SSH-RAW")
        try fixture.waitForState(.connected(sequence: 1))
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: true))
    }

    @Test func nonRaw255ConnectionNeverClaimsItWasConnected() throws {
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connecting(sequence: 1))
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: false))
        try fixture.waitForOutput("press Return to reconnect")
        #expect(fixture.isAlive)

        fixture.writeToTerminal("\n")
        try fixture.waitForState(.connectRequested(sequence: 1))
    }

    @Test func theConnectionPollerEndsWhenTheSupervisorIsKilled() throws {
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            exec /bin/sleep 30
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connecting(sequence: 1))
        let supervisor = fixture.pid
        let children = try Self.children(of: supervisor)
        #expect(children.count == 2)
        defer { children.forEach { kill($0, SIGKILL) } }
        #expect(kill(supervisor, SIGKILL) == 0)
        let deadline = Date().addingTimeInterval(2)
        var alive = children.filter { kill($0, 0) == 0 && !Self.isSleep($0) }
        while !alive.isEmpty && Date() < deadline {
            usleep(50_000)
            alive = alive.filter { kill($0, 0) == 0 }
        }
        #expect(alive.isEmpty)
    }

    private static func children(of pid: pid_t) throws -> [pid_t] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    private static func isSleep(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == "/bin/sleep"
    }

    @Test func ignoresInterruptAndStopSignalsWhileWaitingForControl() throws {
        let fixture = try SupervisorFixture(autoConnect: false, fakeSSH: """
            #!/bin/sh
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.waiting(sequence: 0))
        #expect(kill(fixture.pid, SIGINT) == 0)
        #expect(kill(fixture.pid, SIGTSTP) == 0)
        usleep(100_000)
        #expect(fixture.isAlive)

        fixture.sendControl("connect 1 -\n")
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: false))
        try fixture.waitForOutput("press Return to reconnect")
        fixture.writeToTerminal("\r")
        try fixture.waitForState(.connectRequested(sequence: 1))
    }

    @Test func createsPrivateRuntimeFiles() throws {
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            stty -icanon -isig min 1 time 0
            sleep 1
            exit 0
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connected(sequence: 1))
        #expect(try fixture.permissions(of: "state") == 0o600)
        #expect(try fixture.permissions(of: "pid") == 0o600)
        #expect(try fixture.permissions(of: "ever") == 0o600)
        #expect(try fixture.permissions(of: "control") == 0o600)
        #expect(try fixture.waitForExit() == 0)
    }

    @Test func setsAskpassEnvironmentOnlyForTheSSHChild() throws {
        let token = String(repeating: "a", count: 64)
        let loginPath = "/usr/bin:/bin:/synthetic-login"
        let askpassSocket = "/tmp/chostty-synthetic-askpass.sock"
        let fixture = try SupervisorFixture(
            fakeSSH: """
            #!/bin/sh
            {
                printf 'token=%s\\n' "$CHOSTTY_ASKPASS_TOKEN"
                printf 'socket=%s\\n' "$CHOSTTY_ASKPASS_SOCKET"
                printf 'app=%s\\n' "$SSH_ASKPASS"
                printf 'require=%s\\n' "$SSH_ASKPASS_REQUIRE"
                printf 'path=%s\\n' "$PATH"
                printf 'prompt=%s\\n' "${SSH_ASKPASS_PROMPT+present}"
            } >"${0}.env"
            exit 255
            """,
            askpassSocket: askpassSocket,
            autoConnectToken: token,
            loginPath: loginPath)
        defer { fixture.stop() }

        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: false))
        let environment = try String(contentsOf: fixture.fakeSSHURL.appendingPathExtension("env"), encoding: .utf8)
        #expect(environment.contains("token=\(token)\n"))
        #expect(environment.contains("socket=\(askpassSocket)\n"))
        #expect(environment.contains("app=\(fixture.fakeSSHURL.path)\n"))
        #expect(environment.contains("require=force\n"))
        #expect(environment.contains("path=\(loginPath)\n"))
        #expect(environment.contains("prompt=\n"))
    }

    /// Without a saved password, ssh keeps OpenSSH's own terminal prompts.
    @Test func leavesAskpassUnsetWithoutAToken() throws {
        let fixture = try SupervisorFixture(
            fakeSSH: """
            #!/bin/sh
            {
                printf 'token=%s\\n' "${CHOSTTY_ASKPASS_TOKEN+present}"
                printf 'socket=%s\\n' "${CHOSTTY_ASKPASS_SOCKET+present}"
                printf 'app=%s\\n' "${SSH_ASKPASS+present}"
                printf 'require=%s\\n' "${SSH_ASKPASS_REQUIRE+present}"
            } >"${0}.env"
            exit 255
            """,
            askpassSocket: "/tmp/chostty-synthetic-askpass.sock")
        defer { fixture.stop() }

        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: false))
        let environment = try String(contentsOf: fixture.fakeSSHURL.appendingPathExtension("env"), encoding: .utf8)
        #expect(environment == "token=\nsocket=\napp=\nrequire=\n")
    }
}

final class SupervisorFixture {
    private enum Failure: Error {
        case missingSupervisorScript
        case posix(String)
        case timedOut(String)
    }

    let directory: URL
    let fakeSSHURL: URL
    private let process: Process
    private let control: Int32
    private let input: FileHandle
    private let outputReader: FileHandle
    private var capturedOutput = Data()
    private var stopped = false

    init(
        autoConnect: Bool = true,
        fakeSSH: String,
        askpassSocket: String = "-",
        autoConnectToken: String = "-",
        loginPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let controlURL = directory.appendingPathComponent("control")
        guard mkfifo(controlURL.path, 0o600) == 0 else {
            throw Failure.posix("mkfifo: \(String(cString: strerror(errno)))")
        }
        control = open(controlURL.path, O_RDWR | O_CLOEXEC)
        guard control >= 0 else {
            throw Failure.posix("open control: \(String(cString: strerror(errno)))")
        }

        fakeSSHURL = directory.appendingPathComponent("ssh")
        try fakeSSH.write(to: fakeSSHURL, atomically: true, encoding: .utf8)
        guard chmod(fakeSSHURL.path, 0o700) == 0 else {
            throw Failure.posix("chmod fake ssh: \(String(cString: strerror(errno)))")
        }
        guard let supervisorURL = SSHSupervisorScript.resourceURL() else {
            throw Failure.missingSupervisorScript
        }

        func closeOnExec(_ pipe: Pipe) throws {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                let flags = fcntl(handle.fileDescriptor, F_GETFD)
                guard flags >= 0,
                      fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    throw Failure.posix("fcntl CLOEXEC: \(String(cString: strerror(errno)))")
                }
            }
        }
        let standardInput = Pipe()
        try closeOnExec(standardInput)
        let standardOutput = Pipe()
        try closeOnExec(standardOutput)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q",
            "-e",
            "/dev/null",
            "/bin/sh",
            supervisorURL.path,
            directory.path,
            loginPath,
            "-",
            askpassSocket,
            "--",
            fakeSSHURL.path,
        ]
        // XCTest's injected dynamic-loader paths must not enter the pty child.
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "SSH_ASKPASS_PROMPT": "inherited-prompt",
        ]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardOutput
        try process.run()

        self.process = process
        input = standardInput.fileHandleForWriting
        outputReader = standardOutput.fileHandleForReading
        guard fcntl(outputReader.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw Failure.posix("fcntl: \(String(cString: strerror(errno)))")
        }
        if autoConnect {
            sendControl("connect 1 \(autoConnectToken)\n")
        }
    }

    deinit {
        stop()
    }

    var output: String {
        drainOutput()
        return Self.describePTYOutput(capturedOutput)
    }

    static func describePTYOutput(_ data: Data) -> String {
        if let text = String(bytes: data, encoding: .utf8) {
            return text
        }
        return "Non-UTF-8 PTY bytes: " + data.map { String(format: "\\x%02X", $0) }.joined()
    }

    var isAlive: Bool {
        process.isRunning
    }

    var pid: pid_t {
        guard
            let contents = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
            let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return process.processIdentifier
        }
        return pid
    }

    func sendControl(_ command: String) {
        command.withCString { buffer in
            _ = write(control, buffer, strlen(buffer))
        }
    }

    func writeToTerminal(_ text: String) {
        text.withCString { buffer in
            _ = write(input.fileDescriptor, buffer, strlen(buffer))
        }
    }

    func waitForState(_ expected: SSHPaneStateFile, timeout: TimeInterval = 3) throws {
        try wait(description: "state \(expected)") {
            self.currentState == expected
        }
    }

    var currentState: SSHPaneStateFile? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("state"), encoding: .utf8) else {
            return nil
        }
        return SSHPaneStateFile.parse(text)
    }

    func waitForOutput(_ expected: String, timeout: TimeInterval = 3) throws {
        try wait(description: "output \(expected)", timeout: timeout) {
            self.output.contains(expected)
        }
    }

    func waitForExit(timeout: TimeInterval = 3) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                return process.terminationStatus
            }
            usleep(10_000)
        }
        throw Failure.timedOut("process exit")
    }

    func permissions(of name: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            writeToTerminal("\r")
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                usleep(10_000)
            }
            if process.isRunning {
                process.terminate()
            }
        }
        close(control)
        input.closeFile()
        outputReader.closeFile()
        try? FileManager.default.removeItem(at: directory)
    }

    private func wait(description: String, timeout: TimeInterval = 3, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            usleep(10_000)
        }
        throw Failure.timedOut("\(description); last state: \(String(describing: currentState)); output: \(String(output.suffix(2000)).debugDescription)")
    }

    private func drainOutput() {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(outputReader.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                capturedOutput.append(contentsOf: bytes[0..<Int(count)])
                continue
            }
            if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            }
            return
        }
    }
}
