import Foundation
import Testing
@testable import Ghostty

struct SSHTunnelArgumentsTests {
    @Test func localTunnelUsesExactSecureArgumentsAndDelimiter() throws {
        let paths = paths()
        let definition = tunnel(kind: .local, bindPort: 5432, targetHost: "database", targetPort: 5432)

        #expect(try SSHTunnelArguments.make(for: definition, paths: paths) == [
            "-N",
            "-n",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ForkAfterAuthentication=no",
            "-o", "PermitLocalCommand=no",
            "-L", "127.0.0.1:5432:database:5432",
            "--", "prod",
        ])
    }

    @Test func interactiveTunnelsAskAboutUnknownKeysInsteadOfBatchMode() throws {
        let definition = tunnel(kind: .local, bindPort: 5432, targetHost: "database", targetPort: 5432)
        #expect(try SSHTunnelArguments.make(for: definition, paths: paths(), interactive: true) == [
            "-N",
            "-n",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ForkAfterAuthentication=no",
            "-o", "PermitLocalCommand=no",
            "-L", "127.0.0.1:5432:database:5432",
            "--", "prod",
        ])
    }

    @Test func remoteAndDynamicTunnelsUseExpectedSpecifications() throws {
        let paths = paths()
        let remote = tunnel(kind: .remote, bindPort: 15432, targetHost: "database", targetPort: 5432)
        let dynamic = tunnel(kind: .dynamic, bindPort: 1080)

        #expect(Array(try SSHTunnelArguments.make(for: remote, paths: paths).suffix(4)) == [
            "-R", "127.0.0.1:15432:database:5432", "--", "prod",
        ])
        #expect(Array(try SSHTunnelArguments.make(for: dynamic, paths: paths).suffix(5)) == [
            "PermitLocalCommand=no", "-D", "127.0.0.1:1080", "--", "prod",
        ])
    }

    @Test func bracketsUnbracketedIPv6BindAndTargetAddresses() throws {
        let definition = tunnel(
            kind: .local,
            bindAddress: "::1",
            bindPort: 5432,
            targetHost: "2001:db8::10",
            targetPort: 5432)

        #expect(Array(try SSHTunnelArguments.make(for: definition, paths: paths()).suffix(4)) == [
            "-L", "[::1]:5432:[2001:db8::10]:5432", "--", "prod",
        ])
    }

    @Test func preservesBracketedIPv6Addresses() throws {
        let definition = tunnel(
            kind: .remote,
            bindAddress: "[::1]",
            bindPort: 5432,
            targetHost: "[2001:db8::10]",
            targetPort: 5432)

        #expect(Array(try SSHTunnelArguments.make(for: definition, paths: paths()).suffix(4)) == [
            "-R", "[::1]:5432:[2001:db8::10]:5432", "--", "prod",
        ])
    }

    @Test func managedHostUsesInjectedManagedHostsFileOnly() throws {
        let paths = paths(managedDirectory: "/tmp/chostty managed")
        let managed = tunnel(
            source: .managed(hostID: UUID()),
            kind: .dynamic,
            bindPort: 1080)
        let config = tunnel(source: .sshConfig, kind: .dynamic, bindPort: 1080)

        let managedArguments = try SSHTunnelArguments.make(for: managed, paths: paths)
        let configArguments = try SSHTunnelArguments.make(for: config, paths: paths)
        #expect(managedArguments.contains("-F"))
        #expect(managedArguments[managedArguments.firstIndex(of: "-F")! + 1] == paths.managedHostsFile.path)
        #expect(!configArguments.contains("-F"))
    }

    @Test func rejectsDefinitionsThatFailValidation() {
        let definitions = [
            invalidPortTunnel(bindPort: 0),
            invalidPortTunnel(bindPort: 65_536),
            invalidTargetTunnel(),
            dynamicTunnelWithTarget(),
            invalidWhitespaceTunnel(),
            externalWithoutConsent(),
            externalWithMismatchedConsent(),
        ]
        for definition in definitions {
            #expect(throws: Error.self) {
                try SSHTunnelArguments.make(for: definition, paths: paths())
            }
        }
    }

    private func paths(managedDirectory: String = "/tmp/chostty") -> SSHPaths {
        SSHPaths(
            home: URL(fileURLWithPath: "/tmp/home"),
            runtimeRoot: URL(fileURLWithPath: "/tmp/runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": managedDirectory])
    }

    private func tunnel(
        source: SSHHostSource = .sshConfig,
        kind: SSHTunnelDefinition.Kind,
        bindAddress: String = "127.0.0.1",
        bindPort: Int,
        targetHost: String? = nil,
        targetPort: Int? = nil,
        externalBindConsent: SSHBindConsent? = nil
    ) -> SSHTunnelDefinition {
        SSHTunnelDefinition(
            id: UUID(),
            name: "Tunnel",
            host: SSHHostReference(source: source, alias: "prod"),
            kind: kind,
            bindAddress: bindAddress,
            bindPort: bindPort,
            targetHost: targetHost,
            targetPort: targetPort,
            externalBindConsent: externalBindConsent)
    }

    private func invalidPortTunnel(bindPort: Int) -> SSHTunnelDefinition {
        tunnel(kind: .dynamic, bindPort: bindPort)
    }

    private func invalidTargetTunnel() -> SSHTunnelDefinition {
        tunnel(kind: .local, bindPort: 5432)
    }

    private func dynamicTunnelWithTarget() -> SSHTunnelDefinition {
        tunnel(kind: .dynamic, bindPort: 1080, targetHost: "database", targetPort: 5432)
    }

    private func invalidWhitespaceTunnel() -> SSHTunnelDefinition {
        tunnel(kind: .dynamic, bindAddress: "127.0.0.1 address", bindPort: 1080)
    }

    private func externalWithoutConsent() -> SSHTunnelDefinition {
        tunnel(kind: .dynamic, bindAddress: "0.0.0.0", bindPort: 1080)
    }

    private func externalWithMismatchedConsent() -> SSHTunnelDefinition {
        tunnel(
            kind: .dynamic,
            bindAddress: "0.0.0.0",
            bindPort: 1080,
            externalBindConsent: SSHBindConsent(
                address: "0.0.0.0",
                port: 1081,
                kind: .dynamic,
                grantedAt: .now))
    }
}
