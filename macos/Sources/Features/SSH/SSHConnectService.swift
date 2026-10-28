import AppKit
import Foundation

enum SSHPlacement: String, Sendable {
    case tab
    case split
}

@MainActor
final class SSHConnectService {
    private unowned let services: SSHServices

    init(services: SSHServices) {
        self.services = services
    }

    func connect(_ entry: SSHHostEntry, placement: SSHPlacement, capability: SSHCapability) {
        guard services.catalog.revalidate(entry.reference) else {
            unavailableAlert(for: entry.reference.alias)
            return
        }

        services.loginEnvironment.value { [weak self, weak capability] login in
            DispatchQueue.main.async {
                guard let self, let capability,
                      let config = self.launchConfiguration(
                        for: SSHPaneBinding(reference: entry.reference, displayDestination: nil),
                        autoConnect: true,
                        login: login)
                else { return }
                if let launchID = config.ssh?.launchID {
                    let source: String
                    switch entry.reference.source {
                    case .managed: source = "managed"
                    case .sshConfig: source = "sshConfig"
                    }
                    SSHLog.logger.notice(
                        "connect.requested id=\(launchID.uuidString, privacy: .public) source=\(source, privacy: .public) placement=\(placement.rawValue, privacy: .public)")
                }

                let surface: Ghostty.SurfaceView?
                switch placement {
                case .tab:
                    surface = (NSApp.delegate as? AppDelegate)?
                        .terminalCommands
                        .createVirtualTab(source: capability.controller.focusedSurface, baseConfig: config)?
                        .focusedSurface
                case .split:
                    guard let focused = capability.controller.focusedSurface else { return }
                    surface = capability.controller.newSplit(
                        at: focused,
                        direction: .right,
                        baseConfig: config)
                }

                guard let surface else { return }
                self.services.recordRecent(entry.reference)
                let snapshot = self.services.catalog.snapshot
                self.services.resolver.resolve(
                    reference: entry.reference,
                    paths: self.services.paths,
                    observations: snapshot.observations,
                    containsMatchExec: snapshot.containsMatchExec,
                    reason: .connect
                ) { result in
                    guard let result else { return }
                    DispatchQueue.main.async {
                        surface.sshChannel?.updateDisplayDestination(result.destination.display)
                        self.services.catalog.updateResolvedDestination(result.destination, for: entry.reference)
                    }
                }
            }
        }
    }

    func launchConfiguration(
        for binding: SSHPaneBinding,
        autoConnect: Bool,
        login: SSHLoginEnvironment? = nil
    ) -> Ghostty.SurfaceConfiguration? {
        if autoConnect && !services.catalog.revalidate(binding.reference) {
            unavailableAlert(for: binding.reference.alias)
            return nil
        }
        guard let executable = Bundle.main.executableURL,
              let supervisor = SSHSupervisorScript.resourceURL(),
              let appDelegate = NSApp.delegate as? AppDelegate
        else { return nil }

        let provenance = SSHTerminalEnvironmentPolicy.currentProvenance()
        let terminal = SSHTerminalEnvironmentPolicy.decide(
            actual: appDelegate.ghostty.config.shellIntegrationFeatures,
            provenance: provenance)
        return SSHLaunch.surfaceConfiguration(
            for: binding,
            autoConnect: autoConnect,
            environment: SSHLaunchEnvironment(
                executableURL: executable,
                supervisorURL: supervisor,
                login: login ?? services.loginEnvironment.load(),
                terminal: terminal,
                paths: services.paths),
            askpassSocketURL: services.askpassSocketURL)
    }

    private func unavailableAlert(for alias: String) {
        let alert = NSAlert()
        alert.messageText = "\(alias) is no longer available."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
