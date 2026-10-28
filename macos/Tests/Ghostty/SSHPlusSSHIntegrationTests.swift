import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHPlusSSHIntegrationTests {
    // +ssh reaches ssh even when the process inherited Chostty askpass state.
    @Test func plusSSHPlacesTermEnvironmentBeforeAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ssh = directory.appendingPathComponent("ssh")
        let record = directory.appendingPathComponent("argv")
        let environmentRecord = directory.appendingPathComponent("environment")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$SSH_RECORD"
        {
            printf 'askpass=%s\\n' "${SSH_ASKPASS-}"
            printf 'require=%s\\n' "${SSH_ASKPASS_REQUIRE-}"
            printf 'display=%s\\n' "${DISPLAY-}"
            printf 'token=%s\\n' "${CHOSTTY_ASKPASS_TOKEN-}"
            printf 'socket=%s\\n' "${CHOSTTY_ASKPASS_SOCKET-}"
            printf 'tunnel=%s\\n' "${CHOSTTY_ASKPASS_TUNNEL-}"
        } > "$SSH_ENVIRONMENT_RECORD"
        """.write(to: ssh, atomically: true, encoding: .utf8)
        #expect(chmod(ssh.path, 0o700) == 0)

        guard let executable = Bundle.main.executableURL else {
            Issue.record("The test host has no executable.")
            return
        }
        // A disposable home keeps the child's config, caches and crash state
        // out of the user's Library.
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "PATH": "\(directory.path):/usr/bin:/bin",
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "TMPDIR": directory.path + "/",
            "SSH_RECORD": record.path,
            "SSH_ENVIRONMENT_RECORD": environmentRecord.path,
            "SSH_ASKPASS": "/tmp/inherited-askpass",
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":inherited-display",
            "CHOSTTY_ASKPASS_TOKEN": "inherited-token",
            "CHOSTTY_ASKPASS_SOCKET": "/tmp/inherited-askpass.sock",
            "CHOSTTY_ASKPASS_TUNNEL": "1",
        ]
        let output = Pipe()

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "+ssh",
            "--forward-env=true",
            "--terminfo=false",
            "--",
            "--",
            "fakehost",
        ]
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let log = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let realHome = NSHomeDirectory()
        #expect(!log.contains(realHome + "/Library"), "\(log)")
        let arguments = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.contains("-o"))
        #expect(arguments.contains("SetEnv=TERM=xterm-256color"))
        #expect(arguments.suffix(2) == ["--", "fakehost"])
        let childEnvironment = try String(contentsOf: environmentRecord, encoding: .utf8)
        #expect(childEnvironment.contains("askpass=/tmp/inherited-askpass\n"))
        #expect(childEnvironment.contains("require=force\n"))
        #expect(childEnvironment.contains("display=:inherited-display\n"))
        #expect(childEnvironment.contains("token=inherited-token\n"))
        #expect(childEnvironment.contains("socket=/tmp/inherited-askpass.sock\n"))
        #expect(childEnvironment.contains("tunnel=1\n"))
    }
}
