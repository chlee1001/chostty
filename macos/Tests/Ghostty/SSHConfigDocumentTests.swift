import Foundation
import Testing
@testable import Ghostty

struct SSHConfigDocumentTests {
    @Test func preservesUntouchedMixedNewlinesCommentsAndUnknownOptions() {
        let source = Data("# preamble\r\nHost legacy\n    HostName legacy.example\r\n    Compression yes\n    UnknownOption keep-this\r\n# trailing comment".utf8)
        let document = SSHConfigDocument(data: source)

        #expect(document.data == source)
    }

    @Test func replacesAddsAndDeletesMarkedBlocksBeforeTheRequiredTail() throws {
        let firstID = UUID()
        let deletedID = UUID()
        let source = """
        # chostty-host-id: \(firstID.uuidString)
        Host db
            HostName old.example
        # chostty-host-id: \(deletedID.uuidString)
        Host cache
            HostName cache.example
        Host outside
            HostName outside.example
        Host *
            Include ~/.ssh/config
            Include /etc/ssh/ssh_config
        """ + "\n"
        var document = SSHConfigDocument(text: source)
        let replacement = try SSHManagedHost(hostID: firstID, alias: "db", hostName: "new.example")
        let addedID = UUID()
        let added = try SSHManagedHost(hostID: addedID, alias: "api", hostName: "api.example")

        try document.upsertManagedHost(replacement)
        try document.upsertManagedHost(added)
        try document.deleteManagedHost(id: deletedID)
        let result = try #require(String(bytes: document.dataForManagedChanges(), encoding: .utf8))

        #expect(result.contains("Host db\n    HostName new.example\n"))
        #expect(result.contains("# chostty-host-id: \(addedID.uuidString)\nHost api\n"))
        #expect(!result.contains("Host cache"))
        #expect(result.contains("Host outside\n    HostName outside.example\n"))
        #expect(result.hasSuffix("Host *\n    Include ~/.ssh/config\n    Include /etc/ssh/ssh_config\n"))
    }

    @Test func appendsTheRequiredTailAndPreservesUnmarkedBlocks() throws {
        let source = "Host outside\r\n    HostName outside.example\r\n    UnknownOption still-here\r\n"
        var document = SSHConfigDocument(text: source)
        let host = try SSHManagedHost(hostID: UUID(), alias: "managed", hostName: "managed.example")

        try document.upsertManagedHost(host)
        let result = try #require(String(bytes: document.dataForManagedChanges(), encoding: .utf8))

        #expect(result.contains("Host outside\r\n    HostName outside.example\r\n    UnknownOption still-here\r\n"))
        #expect(result.hasSuffix("Host *\n    Include ~/.ssh/config\n    Include /etc/ssh/ssh_config\n"))
    }

    @Test func matchesHostPatternsInDocumentOrderAndKeepsMatchBlocks() {
        let document = SSHConfigDocument(text: """
        Host *
            ForwardAgent no
        Host web *.internal !blocked.internal
            User deploy
        Match user root
            PasswordAuthentication no
        Host=web
            Port 2222
        HostName not-a-boundary
        """)

        let blocks = document.blocks(matching: "web")

        #expect(blocks.map(\.kind) == [.host, .host, .match, .host])
        #expect(blocks.map(\.line) == [1, 3, 5, 7])
        #expect(document.blocks(matching: "blocked.internal").map(\.line) == [1, 5])
    }

    @Test func parsesQuotedDirectivesAndHostEqualsBoundaries() {
        let document = SSHConfigDocument(text: """
        Host "build box"
            User "build user"
        Host=api api-alt
            HostName api.example
        HostName not-a-header
        """)

        #expect(document.blocks(matching: "build box").map(\.line) == [1])
        #expect(document.blocks(matching: "api-alt").map(\.line) == [3])
        #expect(document.blocks(matching: "not-a-header").isEmpty)
    }

    @Test func rejectsManagedHostDirectiveInjection() {
        #expect(throws: SSHStoreError.invalidScalarValue("db.example\nHost injected")) {
            _ = try SSHManagedHost(hostID: UUID(), alias: "db", hostName: "db.example\nHost injected")
        }
    }

    @Test func preservesUndecodableUnownedBytesWhenAddingManagedHost() throws {
        let source = Data("Host outside\n    HostName outside.example\n# opaque ".utf8) + Data([0xFF])
        var document = SSHConfigDocument(data: source)
        #expect(document.data == source)

        let host = try SSHManagedHost(hostID: UUID(), alias: "managed", hostName: "managed.example")
        try document.upsertManagedHost(host)

        #expect(document.dataForManagedChanges().starts(with: source + Data([0x0A])))
        let block = try #require(document.managedBlocks.first)
        #expect(try document.managedHost(for: block) == host)
    }

    @Test func refusesUndecodableManagedOptionsWithoutChangingSource() throws {
        let hostID = UUID()
        let source = Data("# chostty-host-id: \(hostID.uuidString)\nHost managed\n    HostName managed.example\n    UnknownOption ".utf8) + Data([0xFF, 0x0A])
        let document = SSHConfigDocument(data: source)
        let block = try #require(document.managedBlocks.first)

        #expect(throws: SSHStoreError.invalidManagedBlock(hostID)) {
            _ = try document.managedHost(for: block)
        }
        #expect(document.data == source)
    }

    @Test func usesFirstScalarValuesAndAccumulatesIdentityFiles() throws {
        let document = SSHConfigDocument(text: """
        # chostty-host-id: \(UUID().uuidString)
        Host managed
            HostName first.example
            HostName second.example
            User first-user
            User second-user
            Port 2201
            Port 2202
            ProxyJump first-jump
            ProxyJump second-jump
            IdentitiesOnly yes
            IdentitiesOnly no
            ForwardAgent no
            ForwardAgent yes
            ServerAliveInterval 0
            ServerAliveInterval 30
            IdentityFile ~/.ssh/first
            IdentityFile /tmp/second
        """)
        let block = try #require(document.managedBlocks.first)
        let host = try document.managedHost(for: block)

        #expect(host.hostName == "first.example")
        #expect(host.user == "first-user")
        #expect(host.port == 2201)
        #expect(host.proxyJump == "first-jump")
        #expect(host.identitiesOnly == true)
        #expect(host.forwardAgent == false)
        #expect(host.serverAliveInterval == 0)
        #expect(host.identityFiles == ["~/.ssh/first", "/tmp/second"])
    }

    @Test(arguments: [
        "HostName \"bad host\"",
        "User \"bad user\"",
        "Port invalid",
        "IdentityFile relative-key",
        "ProxyJump \"bad jump\"",
        "IdentitiesOnly invalid",
        "ForwardAgent invalid",
        "ServerAliveInterval -1",
    ])
    func rejectsInvalidLaterDirectives(_ laterDirective: String) throws {
        let hostID = UUID()
        let document = SSHConfigDocument(text: """
        # chostty-host-id: \(hostID.uuidString)
        Host managed
            HostName first.example
            User first-user
            Port 2201
            IdentityFile /tmp/first
            ProxyJump first-jump
            IdentitiesOnly yes
            ForwardAgent no
            ServerAliveInterval 0
            \(laterDirective)
        """)
        let block = try #require(document.managedBlocks.first)

        #expect(throws: SSHStoreError.invalidManagedBlock(hostID)) {
            _ = try document.managedHost(for: block)
        }
    }
}
