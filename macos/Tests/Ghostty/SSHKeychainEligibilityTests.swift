import Foundation
import Testing
@testable import Ghostty

struct SSHKeychainEligibilityTests {
    @Test func permitsAnExplicitFirstMatchingOwnedBlock() throws {
        let hostID = UUID()
        let source = document(hostID, fields: "User deploy\n    HostName 2001:db8::1\n    Port 2222")
        let result = SSHKeychainEligibility.evaluate(document: source, hostID: hostID)

        #expect(result == .eligible(try SSHTargetFingerprint(hostID: hostID, user: "deploy", hostName: "2001:db8::1", port: 2222)))
    }

    @Test(arguments: [
        ("HostName host\n    Port 22", SSHKeychainEligibility.Reason.missingUser),
        ("User deploy\n    Port 22", .missingHostName),
        ("User deploy\n    HostName host", .missingPort),
    ])
    func requiresEveryEndpointField(_ fields: String, _ reason: SSHKeychainEligibility.Reason) {
        let hostID = UUID()
        #expect(SSHKeychainEligibility.evaluate(document: document(hostID, fields: fields), hostID: hostID) == .ineligible(reason))
    }

    @Test func inheritedOrRemovedPortCannotQualify() {
        let hostID = UUID()
        let inherited = SSHConfigDocument(text: """
        Host *
            Port 22
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
        """)
        let deleted = document(hostID, fields: "User deploy\n    HostName host\n    # Port 22")

        #expect(SSHKeychainEligibility.evaluate(document: inherited, hostID: hostID) == .ineligible(.precededByHost(line: 1)))
        #expect(SSHKeychainEligibility.evaluate(document: deleted, hostID: hostID) == .ineligible(.missingPort))
    }

    @Test func rejectsGlobalScopeOverridesBeforeTheFirstBlock() {
        let hostID = UUID()
        let globalPort = SSHConfigDocument(text: """
        Port 2202
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 2201
        """)
        let globalUser = SSHConfigDocument(text: """
        User inherited
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
        """)
        let globalHostName = SSHConfigDocument(text: """
        HostName inherited.example
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
        """)

        #expect(SSHKeychainEligibility.evaluate(document: globalPort, hostID: hostID) == .ineligible(.scopeOverride(line: 1)))
        #expect(SSHKeychainEligibility.evaluate(document: globalUser, hostID: hostID) == .ineligible(.scopeOverride(line: 1)))
        #expect(SSHKeychainEligibility.evaluate(document: globalHostName, hostID: hostID) == .ineligible(.scopeOverride(line: 1)))
    }

    @Test func rejectsUnresolvedIncludesBeforeOrBetweenOwnedScopeFields() {
        let hostID = UUID()
        let globalInclude = SSHConfigDocument(text: """
        Include ~/.ssh/work
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
        """)
        let betweenFields = SSHConfigDocument(text: """
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            Include ~/.ssh/work
            HostName host
            Port 22
        """)

        #expect(SSHKeychainEligibility.evaluate(document: globalInclude, hostID: hostID) == .ineligible(.includedScope(line: 1)))
        #expect(SSHKeychainEligibility.evaluate(document: betweenFields, hostID: hostID) == .ineligible(.includedScope(line: 4)))
    }

    @Test func allowsNonmatchingOptionsAndIncludesAfterExplicitScopeFields() throws {
        let hostID = UUID()
        let source = SSHConfigDocument(text: """
        Host unrelated
            Compression yes
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
            Include ~/.ssh/after-explicit-fields
        Host *
            Include ~/.ssh/config
        """)

        #expect(SSHKeychainEligibility.evaluate(document: source, hostID: hostID) == .eligible(
            try SSHTargetFingerprint(hostID: hostID, user: "deploy", hostName: "host", port: 22)))
    }

    @Test func rejectsOpaqueDocumentBytesWithoutMutation() {
        let hostID = UUID()
        var source = Data([0xFF, 0x0A])
        source.append(document(hostID).data)
        let opaque = SSHConfigDocument(data: source)

        #expect(SSHKeychainEligibility.evaluate(document: opaque, hostID: hostID) == .ineligible(.invalidConfiguration))
        #expect(opaque.data == source)
    }

    @Test func rejectsEarlierMatchingHostOrAnyMatch() {
        let hostID = UUID()
        let wildcard = SSHConfigDocument(text: """
        Host *
            User ignored
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
        """)
        let match = SSHConfigDocument(text: """
        Match all
            User ignored
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
        """)

        #expect(SSHKeychainEligibility.evaluate(document: wildcard, hostID: hostID) == .ineligible(.precededByHost(line: 1)))
        #expect(SSHKeychainEligibility.evaluate(document: match, hostID: hostID) == .ineligible(.precededByMatch(line: 1)))
    }

    @Test(arguments: ["Match host deploy", "Match originalhost deploy", "Match exec false", "Match canonical",
                     "Host other deploy", "Host dep?oy", "Host * !other"])
    func rejectsPrecedingConditionalAndPatternListPortOverrides(_ header: String) throws {
        let hostID = UUID()
        let suffix = try #require(String(data: document(hostID).data, encoding: .utf8))
        let source = SSHConfigDocument(text: "\(header)\n    Port 2202\n" + suffix)
        let expected: SSHKeychainEligibility.Reason = header.hasPrefix("Match")
            ? .precededByMatch(line: 1) : .precededByHost(line: 1)
        #expect(SSHKeychainEligibility.evaluate(document: source, hostID: hostID) == .ineligible(expected))
    }

    @Test(arguments: ["Host other", "Host DEPLOY", "Host * !deploy"])
    func permitsNonmatchingHostPortFieldsUsingOpenSSHCaseSemantics(_ header: String) throws {
        let hostID = UUID()
        let suffix = try #require(String(data: document(hostID).data, encoding: .utf8))
        let source = SSHConfigDocument(text: "\(header)\n    Port 2202\n" + suffix)
        #expect(SSHKeychainEligibility.evaluate(document: source, hostID: hostID) == .eligible(
            try SSHTargetFingerprint(hostID: hostID, user: "deploy", hostName: "host", port: 22)))
    }

    @Test func followingTailDoesNotAffectEligibility() throws {
        let hostID = UUID()
        let source = """
        # chostty-host-id: \(hostID.uuidString)
        Host deploy
            User deploy
            HostName host
            Port 22
        Host *
            Include ~/.ssh/config
        """
        let result = SSHKeychainEligibility.evaluate(document: SSHConfigDocument(text: source), hostID: hostID)
        #expect(result == .eligible(try SSHTargetFingerprint(hostID: hostID, user: "deploy", hostName: "host", port: 22)))
    }

    @Test func firstDuplicateScalarWinsAndAliasDoesNotChangeFingerprint() throws {
        let hostID = UUID()
        let duplicate = document(hostID, fields: "User deploy\n    HostName host\n    Port 2222\n    Port 22")
        let renamed = document(hostID, alias: "new-alias")
        let original = document(hostID, alias: "old-alias")
        let expected = try SSHTargetFingerprint(hostID: hostID, user: "deploy", hostName: "host", port: 2222)

        #expect(SSHKeychainEligibility.evaluate(document: duplicate, hostID: hostID) == .eligible(expected))
        #expect(SSHKeychainEligibility.evaluate(document: renamed, hostID: hostID) == SSHKeychainEligibility.evaluate(document: original, hostID: hostID))
    }

    @Test func endpointChangesProduceDifferentFingerprintsAndDuplicateOwnerFailsClosed() throws {
        let hostID = UUID()
        let changed = document(hostID, fields: "User deploy\n    HostName other\n    Port 22")
        let duplicateOwner = SSHConfigDocument(text: """
        # chostty-host-id: \(hostID.uuidString)
        Host one
            User deploy
            HostName host
            Port 22
        # chostty-host-id: \(hostID.uuidString)
        Host two
            User deploy
            HostName host
            Port 22
        """)
        let original = try #require(eligibleFingerprint(SSHKeychainEligibility.evaluate(document: document(hostID), hostID: hostID)))
        let changedFingerprint = try #require(eligibleFingerprint(SSHKeychainEligibility.evaluate(document: changed, hostID: hostID)))

        #expect(original != changedFingerprint)
        #expect(SSHKeychainEligibility.evaluate(document: duplicateOwner, hostID: hostID) == .ineligible(.blockNotFound))
    }

    private func document(_ hostID: UUID, alias: String = "deploy", fields: String = "User deploy\n    HostName host\n    Port 22") -> SSHConfigDocument {
        SSHConfigDocument(text: """
        # chostty-host-id: \(hostID.uuidString)
        Host \(alias)
            \(fields)
        """)
    }

    private func eligibleFingerprint(_ value: SSHKeychainEligibility) -> SSHTargetFingerprint? {
        guard case .eligible(let fingerprint) = value else { return nil }
        return fingerprint
    }
}
