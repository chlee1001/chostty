import Foundation
import Testing
@testable import Ghostty

/// SSH restoration builds a waiting supervisor surface without starting SSH.
@MainActor
@Suite struct MakeFromSnapshotSSHTests {
    private final class CapturedConfiguration {
        var value: Ghostty.SurfaceConfiguration?
    }

    private func binding() -> SSHPaneBinding {
        SSHPaneBinding(
            reference: SSHHostReference(source: .sshConfig, alias: "restore-host"),
            displayDestination: "deploy@restore.example:2201")
    }

    private func waitingConfiguration(
        for binding: SSHPaneBinding,
        autoConnect: Bool,
        root: URL
    ) -> Ghostty.SurfaceConfiguration {
        SSHLaunch.surfaceConfiguration(
            for: binding,
            autoConnect: autoConnect,
            environment: SSHLaunchEnvironment(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                supervisorURL: URL(fileURLWithPath: "/tmp/chostty-ssh-supervisor.sh"),
                login: SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil),
                terminal: SSHTerminalEnvironment(forwardEnv: true, terminfo: false, outcome: .forcedOn),
                paths: SSHPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))))
    }

    @Test func restoredSSHLeafWaitsWithoutSpawningATerminalProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = binding()
        let savedSSH = try #require(PaneSSHSnapshot(binding: binding))
        let leaf = PaneLeafSnapshot(
            uuid: UUID(),
            cwd: nil,
            title: "Saved SSH title",
            ssh: savedSSH)
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .leaf(leaf),
            focusedPaneID: leaf.uuid,
            zoomedPaneID: nil)
        let workspace = WorkspaceSnapshot(
            id: UUID(),
            name: "Workspace",
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: [tab],
            selectedTabID: tab.id)
        let window = WindowSnapshot(
            physicalUUID: UUID(),
            selection: SelectionSnapshot(workspaceID: workspace.id, tabID: tab.id),
            workspaces: [workspace])
        let captured = CapturedConfiguration()

        let graph = try #require(TerminalControllerGraphFactory.makeFromSnapshot(
            ghostty: TerminalControllerTestHarness.sharedApp,
            window: window,
            bindings: .init(
                registry: PendingHydrationRegistry(),
                construct: { config, uuid in
                    captured.value = config
                    guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
                    return Ghostty.SurfaceView(
                        app,
                        baseConfig: config,
                        uuid: uuid,
                        spawnsSurface: false)
                },
                sshConfiguration: { binding, autoConnect in
                    self.waitingConfiguration(for: binding, autoConnect: autoConnect, root: root)
                })))

        #expect(captured.value?.ssh?.binding == binding)
        #expect(captured.value?.ssh?.autoConnect == false)
        #expect(graph.initialSession.ssh == SSHTabPresentation(
            alias: binding.reference.alias,
            destination: binding.displayDestination,
            status: SSHPaneStatus(connection: .waiting, reconnectBlock: nil)))

        let surface = try #require(graph.initialSurfaceTree.first)
        #expect(surface.sshChannel?.binding == binding)
        #expect(surface.sshStatus?.connection == .waiting)
    }
}
