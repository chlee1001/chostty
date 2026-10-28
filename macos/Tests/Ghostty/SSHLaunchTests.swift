import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHLaunchTests {
    @Test func commandSeparatesAliasFromSSHOptions() throws {
        let root = FileManager.default.temporaryDirectory
        let binding = SSHPaneBinding(reference: SSHHostReference(source: .sshConfig, alias: "prod-api"), displayDestination: nil)
        let environment = SSHLaunchEnvironment(
            executableURL: URL(fileURLWithPath: "/Applications/Chostty Beta.app/Contents/MacOS/chostty"),
            supervisorURL: URL(fileURLWithPath: "/Applications/Chostty Beta.app/Contents/Resources/chostty-ssh-supervisor.sh"),
            login: SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil),
            terminal: SSHTerminalEnvironment(forwardEnv: true, terminfo: false, outcome: .forcedOn),
            paths: SSHPaths(home: root, runtimeRoot: root.appendingPathComponent("chostty-ssh-F")))
        let socket = root.appendingPathComponent("explicit broker/broker.sock")
        let config = SSHLaunch.surfaceConfiguration(
            for: binding,
            autoConnect: true,
            environment: environment,
            askpassSocketURL: socket)
        #expect(config.command?.contains("--forward-env=true") == true)
        #expect(config.command?.contains("'\(socket.path)' --") == true)
        #expect(config.command?.contains("CHOSTTY_ASKPASS_TOKEN") == false)
        #expect(config.command?.hasSuffix("--terminfo=false -- -- prod-api") == true)
        #expect(config.ssh?.autoConnect == true)
    }

    @Test func managedCommandQuotesManagedHostsFile() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dataDirectory = root.appendingPathComponent("managed hosts")
        let paths = SSHPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": dataDirectory.path])
        let binding = SSHPaneBinding(
            reference: SSHHostReference(source: .managed(hostID: UUID()), alias: "prod-api"),
            displayDestination: nil)
        let environment = SSHLaunchEnvironment(
            executableURL: URL(fileURLWithPath: "/Applications/Chostty Beta.app/Contents/MacOS/chostty"),
            supervisorURL: URL(fileURLWithPath: "/Applications/Chostty Beta.app/Contents/Resources/chostty-ssh-supervisor.sh"),
            login: SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil),
            terminal: SSHTerminalEnvironment(forwardEnv: true, terminfo: false, outcome: .forcedOn),
            paths: paths)

        let command = SSHLaunch.surfaceConfiguration(for: binding, autoConnect: true, environment: environment).command

        #expect(command?.contains("-- -F '\(paths.managedHostsFile.path)' -- prod-api") == true)
        #expect(command?.hasSuffix("-- -F '\(paths.managedHostsFile.path)' -- prod-api") == true)
    }
}
