import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
@Suite struct SessionSnapshotSSHTests {
    private struct OldPaneLeafSnapshot: Codable, Equatable {
        let uuid: UUID
        let cwd: String?
        let title: String?
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decodeLeaf(ssh: [String: Any]) throws -> PaneLeafSnapshot {
        let object: [String: Any] = [
            "uuid": UUID().uuidString,
            "cwd": "/tmp/workspace",
            "title": "terminal",
            "ssh": ssh,
        ]
        return try JSONDecoder().decode(
            PaneLeafSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    @Test func sshBindingSurvivesSnapshotRoundTrip() throws {
        let binding = SSHPaneBinding(
            reference: SSHHostReference(source: .managed(hostID: UUID()), alias: "prod-api"),
            displayDestination: "deploy@prod-api.example.com:2201"
        )
        let ssh = try #require(PaneSSHSnapshot(binding: binding))
        let leaf = PaneLeafSnapshot(uuid: UUID(), cwd: "/tmp", title: "prod", ssh: ssh)

        let decoded = try JSONDecoder().decode(PaneLeafSnapshot.self, from: try encoder().encode(leaf))

        #expect(decoded == leaf)
        #expect(decoded.ssh?.binding == binding)
    }

    @Test func absentSSHKeyMatchesThePreviousLeafEncoding() throws {
        let uuid = UUID()
        let old = OldPaneLeafSnapshot(uuid: uuid, cwd: "/tmp", title: "terminal")
        let current = PaneLeafSnapshot(uuid: uuid, cwd: "/tmp", title: "terminal", ssh: nil)

        #expect(try encoder().encode(current) == encoder().encode(old))
    }

    @Test func oldSchemaCanDecodeASnapshotWithAnSSHBinding() throws {
        let leaf = PaneLeafSnapshot(
            uuid: UUID(),
            cwd: "/tmp",
            title: "terminal",
            ssh: PaneSSHSnapshot(
                kind: .sshConfig,
                hostID: nil,
                alias: "prod-api",
                displayDestination: "prod.example.com"
            )
        )

        let downgraded = try JSONDecoder().decode(OldPaneLeafSnapshot.self, from: try encoder().encode(leaf))

        #expect(downgraded == OldPaneLeafSnapshot(uuid: leaf.uuid, cwd: leaf.cwd, title: leaf.title))
    }

    @Test func malformedSSHBindingsDoNotDiscardLeafFields() throws {
        let oversized = String(repeating: "x", count: SessionSnapshotValidator.Limits.stringLength + 1)
        let invalidBindings: [[String: Any]] = [
            ["kind": "managed", "alias": "prod-api"],
            ["kind": "sshConfig", "hostID": UUID().uuidString, "alias": "prod-api"],
            ["kind": "sshConfig", "alias": "invalid alias"],
            ["kind": "sshConfig", "alias": oversized],
            ["kind": "sshConfig", "alias": "prod-api", "displayDestination": oversized],
        ]

        for binding in invalidBindings {
            let leaf = try decodeLeaf(ssh: binding)
            #expect(leaf.cwd == "/tmp/workspace")
            #expect(leaf.title == "terminal")
            #expect(leaf.ssh == nil)
        }
    }

    @Test func projectionSanitizesAndBoundsDisplayDestination() throws {
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let runtimeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        var configuration = Ghostty.SurfaceConfiguration()
        configuration.ssh = SSHPaneLaunch(
            binding: SSHPaneBinding(
                reference: SSHHostReference(source: .sshConfig, alias: "prod-api"),
                displayDestination: "\u{001B}" + String(repeating: "x", count: SessionSnapshotValidator.Limits.stringLength + 1)
            ),
            launchID: UUID(),
            runtimeDirectory: runtimeDirectory,
            autoConnect: false
        )
        let view = Ghostty.SurfaceView(app, baseConfig: configuration, spawnsSurface: false)

        let destination = try #require(SessionSnapshotProjection.leaf(from: view).ssh?.displayDestination)

        #expect(destination.utf8.count == SessionSnapshotValidator.Limits.stringLength)
        #expect(!destination.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })
    }

    @Test func snapshotEncodingContainsOnlySSHIdentityFields() throws {
        let leaf = PaneLeafSnapshot(
            uuid: UUID(),
            cwd: "/tmp",
            title: "terminal",
            ssh: PaneSSHSnapshot(
                kind: .sshConfig,
                hostID: nil,
                alias: "prod-api",
                displayDestination: "prod.example.com"
            )
        )
        let object = try #require(JSONSerialization.jsonObject(with: encoder().encode(leaf)) as? [String: Any])
        let ssh = try #require(object["ssh"] as? [String: Any])
        #expect(Set(ssh.keys) == ["kind", "alias", "displayDestination"])
    }
}
