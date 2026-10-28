import AppKit
import Foundation

struct SSHLaunchEnvironment: Sendable {
    let executableURL: URL
    let supervisorURL: URL
    let login: SSHLoginEnvironment
    let terminal: SSHTerminalEnvironment
    let paths: SSHPaths
}

enum SSHLaunch {
    static func surfaceConfiguration(
        for binding: SSHPaneBinding,
        autoConnect: Bool,
        environment: SSHLaunchEnvironment,
        askpassSocketURL: URL? = nil
    ) -> Ghostty.SurfaceConfiguration {
        let launchID = UUID()
        let runtimeDirectory = environment.paths.runtimeRoot.appendingPathComponent(launchID.uuidString, isDirectory: true)
        let launch = SSHPaneLaunch(binding: binding, launchID: launchID, runtimeDirectory: runtimeDirectory, autoConnect: autoConnect)
        let managed: Bool
        if case .managed = binding.reference.source {
            managed = true
        } else {
            managed = false
        }
        var sshArguments: [String] = []
        if managed {
            sshArguments += ["-F", environment.paths.managedHostsFile.path]
        }
        sshArguments += ["--", binding.reference.alias]
        let args = [
            "/usr/bin/env", "/bin/sh", environment.supervisorURL.path,
            runtimeDirectory.path, environment.login.path, environment.login.authSocket ?? "-",
            askpassSocketURL?.path ?? "-", "--",
            environment.executableURL.path, "+ssh",
            "--forward-env=\(environment.terminal.forwardEnv)",
            "--terminfo=\(environment.terminal.terminfo)", "--",
        ] + sshArguments
        let command = args.map(Ghostty.Shell.quote)
        SSHLog.logger.notice(
            "launch.built argc=\(args.count, privacy: .public) managed=\(managed, privacy: .public) forwardEnv=\(environment.terminal.forwardEnv, privacy: .public) terminfo=\(environment.terminal.terminfo, privacy: .public)")
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = command.joined(separator: " ")
        configuration.waitAfterCommand = false
        configuration.ssh = launch
        return configuration
    }
}
