import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHResolverTests {
    @Test func parsesOpenSSHConfigOutput() {
        let result = SSHResolver.parse(data: Data(
            "user deploy\nhostname api.example.test\nport 2201\nidentityfile ~/.ssh/deploy\n".utf8))
        #expect(result?.destination == SSHResolvedDestination(user: "deploy", hostName: "api.example.test", port: 2201))
        #expect(result?.options["identityfile"] == ["~/.ssh/deploy"])
    }

    @Test func rejectsMalformedExplicitPort() {
        let result = SSHResolver.parse(data: Data("hostname api.example.test\nport 2201invalid\n".utf8))
        #expect(result == nil)
    }

    @Test func rejectsUndecodableHostName() {
        let output = Data("hostname api".utf8) + Data([0xFF]) + Data(".example.test\nport 22\n".utf8)
        #expect(SSHResolver.parse(data: output) == nil)
    }

    @Test func resolvesManagedAndSSHConfigReferencesIndependently() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let managedDataDirectory = directory.appendingPathComponent("managed hosts")
        let managedHostsFile = managedDataDirectory.appendingPathComponent("hosts.conf")
        let trace = directory.appendingPathComponent("arguments")
        let ssh = try fakeSSH(
            in: directory,
            script: """
            #!/bin/sh
            printf '%s\\n' "$@" >> "$TRACE"
            config=
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-F" ]; then config=$2; shift 2; else shift; fi
            done
            if [ "$config" = "$MANAGED" ]; then
                printf 'user managed\\nhostname managed.example.test\\nport 2201\\n'
            else
                printf 'user config\nhostname config.example.test\nport 2202\n'
            fi
            """)
        let paths = SSHPaths(
            home: directory,
            runtimeRoot: directory.appendingPathComponent("runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": managedDataDirectory.path])
        #expect(paths.managedHostsFile == managedHostsFile)

        let resolver = SSHResolver(sshURL: ssh, environment: ["TRACE": trace.path, "MANAGED": managedHostsFile.path])
        let managed = await resolve(
            resolver,
            reference: SSHHostReference(source: .managed(hostID: UUID()), alias: "same"),
            paths: paths)
        let config = await resolve(
            resolver,
            reference: SSHHostReference(source: .sshConfig, alias: "same"),
            paths: paths)

        #expect(managed?.destination == SSHResolvedDestination(user: "managed", hostName: "managed.example.test", port: 2201))
        #expect(config?.destination == SSHResolvedDestination(user: "config", hostName: "config.example.test", port: 2202))
        let arguments = try String(contentsOf: trace, encoding: .utf8)
        #expect(arguments.contains("-F\n\(managedHostsFile.path)\n"))
    }

    // Managed values override the same user-config host while other values inherit.
    @Test func managedHostConfigurationOverridesAndInheritsWithOpenSSH() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let userConfig = home.appendingPathComponent(".ssh/config")
        let managedDirectory = directory.appendingPathComponent("managed hosts", isDirectory: true)
        let managedHostsFile = managedDirectory.appendingPathComponent("hosts.conf")
        try FileManager.default.createDirectory(at: userConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        try """
        Host shared
            User inherited
            ServerAliveInterval 7
        """.write(to: userConfig, atomically: true, encoding: .utf8)
        #expect(chmod(userConfig.path, 0o600) == 0)
        try """
        # chostty-host-id: \(UUID().uuidString)
        Host shared
            HostName shared.example.test
            User managed
            Port 2222
        Host *
            Include \(userConfig.path)
        """.write(to: managedHostsFile, atomically: true, encoding: .utf8)
        #expect(chmod(managedHostsFile.path, 0o600) == 0)

        let paths = SSHPaths(
            home: home,
            userConfig: userConfig,
            runtimeRoot: directory.appendingPathComponent("runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": managedDirectory.path])
        let result = await resolve(
            SSHResolver(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                environment: [
                    "HOME": home.path,
                    "CFFIXED_USER_HOME": home.path,
                ]),
            reference: SSHHostReference(source: .managed(hostID: UUID()), alias: "shared"),
            paths: paths)

        #expect(result?.destination == SSHResolvedDestination(user: "managed", hostName: "shared.example.test", port: 2222))
        #expect(result?.options["serveraliveinterval"]?.last == "7")
    }

    @Test func deniesMatchExecWithoutStartingSSH() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("ran")
        let ssh = try fakeSSH(
            in: directory,
            script: "#!/bin/sh\n: > \"$SENTINEL\"\nprintf 'hostname host\nport 22\n'\n")
        let paths = SSHPaths(home: directory, runtimeRoot: directory.appendingPathComponent("runtime"))

        let result = await resolve(
            SSHResolver(sshURL: ssh, environment: ["SENTINEL": sentinel.path]),
            reference: SSHHostReference(source: .sshConfig, alias: "host"),
            paths: paths,
            containsMatchExec: true)

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func allowsExplicitMatchExecConsent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("ran")
        let ssh = try fakeSSH(
            in: directory,
            script: "#!/bin/sh\n: > \"$SENTINEL\"\nprintf 'hostname host\nport 22\n'\n")
        let paths = SSHPaths(home: directory, runtimeRoot: directory.appendingPathComponent("runtime"))

        let result = await resolve(
            SSHResolver(sshURL: ssh, environment: ["SENTINEL": sentinel.path]),
            reference: SSHHostReference(source: .sshConfig, alias: "host"),
            paths: paths,
            containsMatchExec: true,
            allowMatchExec: true)

        #expect(result?.destination.hostName == "host")
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func rejectsUnsafeAliasWithoutStartingSSH() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("ran")
        let ssh = try fakeSSH(
            in: directory,
            script: "#!/bin/sh\n: > \"$SENTINEL\"\nprintf 'hostname host\nport 22\n'\n")
        let paths = SSHPaths(home: directory, runtimeRoot: directory.appendingPathComponent("runtime"))

        let result = await resolve(
            SSHResolver(sshURL: ssh, environment: ["SENTINEL": sentinel.path]),
            reference: SSHHostReference(source: .sshConfig, alias: "-option"),
            paths: paths)

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func changingObservationsInvalidatesCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = directory.appendingPathComponent("count")
        let ssh = try fakeSSH(
            in: directory,
            script: "#!/bin/sh\nprintf x >> \"$COUNT\"\nprintf 'hostname host\nport 22\n'\n")
        let paths = SSHPaths(home: directory, runtimeRoot: directory.appendingPathComponent("runtime"))
        let resolver = SSHResolver(sshURL: ssh, environment: ["COUNT": count.path])
        let reference = SSHHostReference(source: .sshConfig, alias: "host")

        _ = await resolve(resolver, reference: reference, paths: paths, observations: ["/config": .missing])
        _ = await resolve(resolver, reference: reference, paths: paths, observations: ["/config": .missing])
        _ = await resolve(resolver, reference: reference, paths: paths, observations: ["/config": .unreadable(EACCES)])

        #expect(try String(contentsOf: count, encoding: .utf8) == "xx")
    }

    @Test func returnsAtDeadlineWithoutWaitingForInheritedWriter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\n/bin/sleep 30 &\n/bin/sleep 30\n"
            .write(to: ssh, atomically: true, encoding: .utf8)
        #expect(chmod(ssh.path, 0o700) == 0)
        let paths = SSHPaths(home: directory, runtimeRoot: directory.appendingPathComponent("runtime"))

        let resolver = SSHResolver(sshURL: ssh, timeout: 0.05)
        let started = Date()
        let value = await resolve(
            resolver,
            reference: SSHHostReference(source: .sshConfig, alias: "host"),
            paths: paths)
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    private func resolve(
        _ resolver: SSHResolver,
        reference: SSHHostReference,
        paths: SSHPaths,
        observations: [String: SSHFileObservation] = [:],
        containsMatchExec: Bool = false,
        allowMatchExec: Bool = false
    ) async -> SSHResolver.Result? {
        await withCheckedContinuation { continuation in
            resolver.resolve(
                reference: reference,
                paths: paths,
                observations: observations,
                containsMatchExec: containsMatchExec,
                reason: .explicit(allowMatchExec: allowMatchExec)) {
                    continuation.resume(returning: $0)
                }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fakeSSH(
        in directory: URL,
        script: String
    ) throws -> URL {
        let ssh = directory.appendingPathComponent("ssh")
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        #expect(chmod(ssh.path, 0o700) == 0)
        return ssh
    }
}
