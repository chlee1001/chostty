import Foundation
import Testing
@testable import Ghostty

struct SSHBindConsentTests {
    @Test func loopbackAddressesDoNotRequireConsent() {
        #expect(!SSHBindConsent.requiresConsent(for: "127.0.0.1"))
        #expect(!SSHBindConsent.requiresConsent(for: "::1"))
        #expect(!SSHBindConsent.requiresConsent(for: "[::1]"))
        #expect(SSHBindConsent.requiresConsent(for: "[::]"))
        #expect(!SSHBindConsent.requiresConsent(for: "LOCALHOST"))
        #expect(SSHBindConsent.requiresConsent(for: "127.0.0.2"))
        #expect(SSHBindConsent.requiresConsent(for: "0.0.0.0"))
        #expect(SSHBindConsent.requiresConsent(for: "localhost."))
    }

    @Test func consentOnlyMatchesItsExactAddressPortAndKind() {
        let consent = SSHBindConsent(address: "0.0.0.0", port: 1080, kind: .dynamic, grantedAt: .now)

        #expect(consent.matches(address: "0.0.0.0", port: 1080, kind: .dynamic))
        #expect(!consent.matches(address: "0.0.0.0", port: 1081, kind: .dynamic))
        #expect(!consent.matches(address: "0.0.0.0", port: 1080, kind: .local))
        #expect(!consent.matches(address: "0.0.0.1", port: 1080, kind: .dynamic))
    }

    @Test func changingConsentTupleInvalidatesTunnel() throws {
        let consent = SSHBindConsent(address: "0.0.0.0", port: 1080, kind: .dynamic, grantedAt: .now)
        var tunnel = SSHTunnelDefinition(
            id: UUID(),
            name: "Proxy",
            host: SSHHostReference(source: .sshConfig, alias: "proxy"),
            kind: .dynamic,
            bindAddress: "0.0.0.0",
            bindPort: 1080,
            targetHost: nil,
            targetPort: nil,
            externalBindConsent: consent
        )

        try tunnel.validate()
        tunnel.bindPort = 1081

        #expect(throws: SSHTunnelDefinitionError.invalidExternalBindConsent) {
            try tunnel.validate()
        }
    }
}
