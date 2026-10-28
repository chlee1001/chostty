import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHTabPresentationTests {
    private func surface(ssh: Bool, directory: URL) throws -> Ghostty.SurfaceView {
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        var config = Ghostty.SurfaceConfiguration()
        if ssh {
            let binding = SSHPaneBinding(
                reference: SSHHostReference(source: .sshConfig, alias: "prod"),
                displayDestination: "deploy@prod.example.com")
            config.ssh = SSHPaneLaunch(
                binding: binding,
                launchID: UUID(),
                runtimeDirectory: directory,
                autoConnect: false)
        }
        return Ghostty.SurfaceView(app, baseConfig: config, spawnsSurface: false)
    }

    @Test func firstSSHLeafDrivesTabPresentationAfterAddingLocalLeftPane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = try surface(ssh: true, directory: root.appendingPathComponent("ssh"))
        let local = try surface(ssh: false, directory: root.appendingPathComponent("local"))
        let tree = try SplitTree(view: ssh).inserting(view: local, at: ssh, direction: .left)
        let session = TerminalSessionState(id: UUID(), surfaceTree: tree)
        let workspace = WorkspaceSession(id: UUID(), name: "Tests", tabs: [session], selectedTabID: session.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: session.id)))

        controller.rebuildSessionMetadataSubscriptions()
        let presentation = try #require(session.ssh)
        #expect(presentation.alias == "prod")
        #expect(presentation.destination == "deploy@prod.example.com")
        #expect(presentation.status.connection == .waiting)
    }

    @Test func rearrangingSameLeavesKeepsSSHPresentationCurrent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = try surface(ssh: true, directory: root.appendingPathComponent("ssh"))
        let local = try surface(ssh: false, directory: root.appendingPathComponent("local"))
        let initial = try SplitTree(view: ssh).inserting(view: local, at: ssh, direction: .right)
        let session = TerminalSessionState(id: UUID(), surfaceTree: initial)
        let workspace = WorkspaceSession(id: UUID(), name: "Tests", tabs: [session], selectedTabID: session.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: session.id)))

        session.surfaceTree = try SplitTree(view: local).inserting(view: ssh, at: local, direction: .left)
        ssh.sshStatus = SSHPaneStatus(connection: .connected, reconnectBlock: nil)
        controller.rebuildSessionMetadataSubscriptions()
        #expect(session.ssh?.status.connection == .connected)
    }
}
