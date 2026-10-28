import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHJumpHostCheckTests {
    @Test(arguments: [
        ("ubuntu@192.168.219.219:2222", "ubuntu", "192.168.219.219", "2222"),
        ("bastion", "", "bastion", ""),
        ("[fe80::1]:22", "", "fe80::1", "22"),
        ("ssh://qa@gateway:2200", "qa", "gateway", "2200"),
        ("ubuntu@", "ubuntu", "", ""),
        (":22", "", "", "22"),
    ])
    func parsesAndComposesOneHop(value: String, user: String, host: String, port: String) {
        let hop = SSHProxyJumpHop(parsing: value)
        #expect(hop == SSHProxyJumpHop(user: user, host: host, port: port))
        #expect(SSHProxyJumpHop(parsing: hop.value) == hop)
    }

    @Test(arguments: ["bastion", "ubuntu@10.0.0.1:2222", "a,ubuntu@b:22", "[fe80::1]:22", "ssh://qa@gate:2200"])
    func acceptsWellFormedValues(value: String) {
        #expect(SSHProxyJump.isValid(value))
    }

    @Test(arguments: [
        "", "ubuntu@", ":22", "a,,b", "host:0", "host:http", "-oProxyCommand=x", "two words",
        "host:", "@host", "[::1]junk", "a,fe80::1", "[not-ipv6]:22",
    ])
    func rejectsMalformedValues(value: String) {
        #expect(!SSHProxyJump.isValid(value))
    }

    @Test func checksOnlyASingleHop() {
        #expect(SSHProxyJump.isSingleHop("ubuntu@gate:22"))
        #expect(!SSHProxyJump.isSingleHop("first,second"))
        #expect(SSHJumpHostChecker.arguments(proxyJump: "first,second", configFile: nil) == nil)
    }

    @Test func buildsHardenedArgumentsForOneHop() throws {
        let config = URL(fileURLWithPath: "/tmp/hosts.conf")
        let direct = try #require(SSHJumpHostChecker.arguments(proxyJump: "ubuntu@second:2222", configFile: config))
        #expect(direct.options == ["-F", "/tmp/hosts.conf"] + SSHJumpHostChecker.hardening)
        #expect(direct.destination == ["--", "ssh://ubuntu@second:2222"])
        for option in [
            "BatchMode=yes", "StrictHostKeyChecking=yes", "ControlPath=none", "ControlMaster=no",
            "ForwardAgent=no", "ClearAllForwardings=yes", "RemoteCommand=none", "SessionType=default",
            "PermitLocalCommand=no", "ForkAfterAuthentication=no",
        ] {
            #expect(direct.options.contains(option), "\(option)")
        }

        let alias = try #require(SSHJumpHostChecker.arguments(proxyJump: "bastion", configFile: nil))
        #expect(!alias.options.contains("-F"))
        #expect(!alias.options.contains("-J"))
        #expect(alias.destination == ["--", "bastion"])
        #expect(SSHJumpHostChecker.arguments(proxyJump: "ubuntu@", configFile: nil) == nil)
    }

    @Test func classifiesSSHOutcomes() {
        let label = "qa@gate:22"
        func classify(_ status: Int32?, _ stderr: String) -> SSHJumpHostCheckResult {
            SSHJumpHostChecker.classify(status: status, errorOutput: Data(stderr.utf8), label: label)
        }
        #expect(classify(0, "") == .signedIn(label))
        #expect(classify(1, "This account is currently not available.") == .signedIn(label))
        #expect(SSHJumpHostChecker.classify(status: nil, timedOut: true, errorOutput: Data(), label: label)
            == .unreachable(label, reason: "timed out."))
        #expect(classify(nil, "") == .failed(label, reason: "ssh was stopped."))
        #expect(classify(255, "qa@gate: Permission denied (publickey,password).")
            == .authenticationRefused(label, passwordOffered: true))
        #expect(classify(255, "qa@gate: Permission denied (publickey).")
            == .authenticationRefused(label, passwordOffered: false))
        #expect(classify(255, "Received disconnect from 10.0.0.1: Too many authentication failures")
            == .authenticationRefused(label, passwordOffered: false))
        #expect(classify(255, "channel 0: open failed: administratively prohibited: open failed") == .signedIn(label))
        #expect(classify(255, "No ED25519 host key is known for gate.\nHost key verification failed.") == .hostKeyUnknown(label))
        #expect(classify(255, "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nHost key verification failed.")
            == .hostKeyChanged(label))
        #expect(classify(255, "ssh: connect to host gate port 22: Connection refused")
            == .unreachable(label, reason: "ssh: connect to host gate port 22: Connection refused"))
        #expect(classify(255, "Bad configuration option: nope") == .failed(label, reason: "Bad configuration option: nope"))
        #expect(classify(255, "") == .failed(label, reason: "ssh exited with status 255."))
    }

    @Test func checksTheResolvedDestinationWithoutPrompting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("trace")
        let ssh = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$TRACE"
        [ -t 0 ] && echo tty >> "$TRACE"
        [ -n "$SSH_ASKPASS" ] && echo askpass >> "$TRACE"
        if [ "$1" = "-G" ]; then printf 'user qa\\nhostname gate\\nport 2222\\n'; exit 0; fi
        echo 'qa@gate: Permission denied (publickey).' >&2
        exit 255

        """.write(to: ssh, atomically: true, encoding: .utf8)
        #expect(chmod(ssh.path, 0o700) == 0)
        let checker = SSHJumpHostChecker(
            sshURL: ssh,
            environment: ["TRACE": trace.path, "SSH_ASKPASS": "/bin/echo", "PATH": "/usr/bin:/bin"])

        let result = await withCheckedContinuation { continuation in
            checker.check(proxyJump: "qa@gate:2222", configFile: nil, containsMatchExec: false, allowMatchExec: false) {
                continuation.resume(returning: $0)
            }
        }

        #expect(result == .authenticationRefused("qa@gate:2222", passwordOffered: false))
        let lines = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("-G ") == true)
        #expect(lines.last?.hasSuffix("-- ssh://qa@gate:2222 true") == true)
        #expect(lines.allSatisfy { $0.contains("BatchMode=yes") })
    }

    @Test func usesTheLoginPathAndAgentWithoutAnyPrompter() {
        let base = [
            "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/app-agent", "SSH_ASKPASS": "/bin/echo",
            "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "CHOSTTY_ASKPASS_SOCKET": "/tmp/s", "LANG": "C",
        ]
        let login = SSHLoginEnvironment(path: "/opt/homebrew/bin:/usr/bin:/bin", authSocket: "/tmp/login-agent")
        #expect(SSHJumpHostChecker.environment(base: base, login: login) == [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/login-agent", "LANG": "C",
        ])
        let noAgent = SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil)
        #expect(SSHJumpHostChecker.environment(base: base, login: noAgent)["SSH_AUTH_SOCK"] == nil)
        #expect(SSHJumpHostChecker.environment(base: base, login: nil) == [
            "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/app-agent", "LANG": "C",
        ])
    }

    @Test func reportsUnresolvedWhenSSHCannotResolveTheJumpHost() async throws {
        let checker = SSHJumpHostChecker(sshURL: URL(fileURLWithPath: "/usr/bin/false"))
        let result = await withCheckedContinuation { continuation in
            checker.check(proxyJump: "bastion", configFile: nil, containsMatchExec: false, allowMatchExec: false) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result == .unresolved)
    }

    @Test func refusesMatchExecWithoutConsentBeforeRunningSSH() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("ran")
        let ssh = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\n: > \"$SENTINEL\"\nexit 1\n".write(to: ssh, atomically: true, encoding: .utf8)
        #expect(chmod(ssh.path, 0o700) == 0)
        let checker = SSHJumpHostChecker(sshURL: ssh, environment: ["SENTINEL": sentinel.path])
        let result = await withCheckedContinuation { continuation in
            checker.check(proxyJump: "bastion", configFile: nil, containsMatchExec: true, allowMatchExec: false) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result == .unresolved)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func reportsATimeoutWithoutWaitingForAnInheritedWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        if [ "$1" = "-G" ]; then printf 'hostname gate\\nport 22\\n'; exit 0; fi
        /bin/sleep 30 &
        /bin/sleep 30

        """.write(to: ssh, atomically: true, encoding: .utf8)
        #expect(chmod(ssh.path, 0o700) == 0)
        let checker = SSHJumpHostChecker(sshURL: ssh, environment: ["PATH": "/usr/bin:/bin"], timeout: 0.3)
        let started = Date()
        let result = await withCheckedContinuation { continuation in
            checker.check(proxyJump: "gate", configFile: nil, containsMatchExec: false, allowMatchExec: false) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result == .unreachable("gate:22", reason: "timed out."))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
