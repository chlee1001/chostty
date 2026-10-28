import Foundation
import Testing
@testable import Ghostty

@MainActor
struct CommandPaletteSSHOptionsTests {
    private func host(_ alias: String, isFavorite: Bool = false) -> SSHHostEntry {
        SSHHostEntry(
            reference: SSHHostReference(source: .sshConfig, alias: alias),
            definedIn: URL(fileURLWithPath: "/tmp/config"),
            line: 1,
            siblingAliases: [alias],
            displayName: nil,
            isFavorite: isFavorite,
            resolved: nil)
    }

    @Test func noCapabilityProducesNoSSHCommands() {
        #expect(TerminalCommandPaletteView.sshCommandOptions(isAvailable: false, hosts: [host("prod")]) { _ in }.isEmpty)
    }

    @Test func optionsHaveExpectedTitlesCountAndActions() {
        let hosts = [host("prod"), host("staging")]
        var actions: [TerminalCommandPaletteView.SSHCommandAction] = []

        let options = TerminalCommandPaletteView.sshCommandOptions(
            isAvailable: true,
            hosts: hosts
        ) { actions.append($0) }

        #expect(options.count == hosts.count * 2 + 1)
        #expect(options.map(\.title) == [
            "SSH: Connect to prod",
            "SSH: Connect to prod in Split",
            "SSH: Connect to staging",
            "SSH: Connect to staging in Split",
            "SSH: Manage Hosts…",
        ])
        options[0].action()
        options[1].action()
        #expect(actions.count == 2)
        if case let .connect(reference) = actions[0] {
            #expect(reference == hosts[0].reference)
        } else {
            Issue.record("Expected connect action.")
        }
        if case let .connectInSplit(reference) = actions[1] {
            #expect(reference == hosts[0].reference)
        } else {
            Issue.record("Expected split action.")
        }
        options[4].action()
        if case .manageHosts? = actions.last {
            #expect(actions.count == 3)
        } else {
            Issue.record("Expected host management action.")
        }
    }

    @Test func hostsKeepCatalogOrder() {
        let options = TerminalCommandPaletteView.sshCommandOptions(
            isAvailable: true,
            hosts: [host("zeta", isFavorite: true), host("omega", isFavorite: true), host("beta"), host("alpha")]
        ) { _ in }

        #expect(options.map(\.title) == [
            "SSH: Connect to zeta",
            "SSH: Connect to zeta in Split",
            "SSH: Connect to omega",
            "SSH: Connect to omega in Split",
            "SSH: Connect to beta",
            "SSH: Connect to beta in Split",
            "SSH: Connect to alpha",
            "SSH: Connect to alpha in Split",
            "SSH: Manage Hosts…",
        ])
    }

    @Test func tunnelsOfferStartWhenStoppedAndStopWhenRunning() {
        let reference = SSHHostReference(source: .sshConfig, alias: "prod")
        let stopped = SSHTunnelDefinition(
            id: UUID(), name: "db", host: reference, kind: .local,
            bindPort: 15432, targetHost: "localhost", targetPort: 5432)
        let running = SSHTunnelDefinition(
            id: UUID(), name: "socks", host: reference, kind: .dynamic, bindPort: 1080)
        var actions: [TerminalCommandPaletteView.SSHCommandAction] = []

        let options = TerminalCommandPaletteView.sshCommandOptions(
            isAvailable: true,
            hosts: [],
            tunnels: [
                .init(definition: stopped, isRunning: false),
                .init(definition: running, isRunning: true),
            ]
        ) { actions.append($0) }

        #expect(options.map(\.title) == [
            "SSH: Start Tunnel db",
            "SSH: Stop Tunnel socks",
            "SSH: Manage Hosts…",
        ])
        options[0].action()
        options[1].action()
        guard actions.count == 2,
              case let .startTunnel(startID) = actions[0],
              case let .stopTunnel(stopID) = actions[1]
        else {
            Issue.record("Expected start and stop tunnel actions.")
            return
        }
        #expect(startID == stopped.id)
        #expect(stopID == running.id)
    }

    /// The palette's alphabetical sort must not undo favorites-first.
    @Test func mergedPaletteKeepsSSHFavoritesFirstAsOneBlock() {
        let ssh = TerminalCommandPaletteView.sshCommandOptions(
            isAvailable: true,
            hosts: [host("zeta", isFavorite: true), host("beta")]
        ) { _ in }
        let others = ["Toggle Fullscreen", "New Tab", "Split Right", "Switch to: Tests"].map {
            CommandOption(title: $0) {}
        }

        let merged = TerminalCommandPaletteView.mergeCommandOptions(updates: [], others: others, ssh: ssh)

        #expect(merged.map(\.title) == [
            "New Tab",
            "Split Right",
            "SSH: Connect to zeta",
            "SSH: Connect to zeta in Split",
            "SSH: Connect to beta",
            "SSH: Connect to beta in Split",
            "SSH: Manage Hosts…",
            "Switch to: Tests",
            "Toggle Fullscreen",
        ])
    }
}
