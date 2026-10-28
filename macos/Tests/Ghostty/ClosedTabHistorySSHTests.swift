import Foundation
import Testing
@testable import Ghostty

@MainActor
@Suite struct ClosedTabHistorySSHTests {
    private func binding() -> SSHPaneBinding {
        SSHPaneBinding(
            reference: SSHHostReference(source: .managed(hostID: UUID()), alias: "closed-host"),
            displayDestination: "ops@closed.example")
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

    @Test func recordKeepsTheFirstSSHBindingWhenItsIndexChanges() {
        let binding = binding()
        let record = ClosedTabHistory.Record(
            workspaceID: UUID(),
            workspaceName: "Workspace",
            index: 1,
            title: "SSH tab",
            titleOverride: nil,
            pwd: nil,
            tabColor: .none,
            ssh: binding)

        let reindexed = record.withIndex(4)
        #expect(reindexed.index == 4)
        #expect(reindexed.ssh == binding)
    }

    @Test func closingATabCapturesItsFirstSSHBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = binding()
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let sshSurface = Ghostty.SurfaceView(
            app,
            baseConfig: waitingConfiguration(for: binding, autoConnect: false, root: root),
            spawnsSurface: false)
        let sshSession = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree(view: sshSurface))
        let localSession = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)))
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Workspace",
            tabs: [sshSession, localSession],
            selectedTabID: localSession.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: localSession.id)))

        controller.closeWorkspaceTab(sshSession.id)

        #expect(controller.closedTabHistory.entries.last?.records.first?.ssh == binding)
    }

    @Test func duplicateSSHRejectsAnAliasRemovedDuringRevalidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = binding()
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let sshSession = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree(view: Ghostty.SurfaceView(
                app,
                baseConfig: waitingConfiguration(for: binding, autoConnect: false, root: root),
                spawnsSurface: false)))
        let localSession = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)))
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Workspace",
            tabs: [sshSession, localSession],
            selectedTabID: localSession.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: localSession.id)))

        #expect(controller.duplicateTab(sshSession.id, sshConfiguration: { _, _ in nil }) == nil)
        #expect(controller.workspaceStore.workspace(forTabID: sshSession.id)?.tabs.count == 2)
    }

    // A duplicated SSH tab requests an immediate connection instead of reopening waiting.
    @Test func duplicatedSSHConfigurationAutoConnects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = binding()
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let sshSession = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree(view: Ghostty.SurfaceView(
                app,
                baseConfig: waitingConfiguration(for: binding, autoConnect: false, root: root),
                spawnsSurface: false)))
        let localSession = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)))
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Workspace",
            tabs: [sshSession, localSession],
            selectedTabID: localSession.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: localSession.id)))
        var requestedAutoConnect: Bool?

        #expect(controller.duplicateTab(sshSession.id, sshConfiguration: { _, autoConnect in
            requestedAutoConnect = autoConnect
            return nil
        }) == nil)
        #expect(requestedAutoConnect == true)

        let config = waitingConfiguration(for: binding, autoConnect: true, root: root)
        let duplicateSurface = Ghostty.SurfaceView(app, baseConfig: config, spawnsSurface: false)
        #expect(duplicateSurface.sshChannel?.autoConnect == true)
    }

    @Test func reopenedSSHRecordBuildsAWaitingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding = binding()
        let record = ClosedTabHistory.Record(
            workspaceID: UUID(),
            workspaceName: "Workspace",
            index: 0,
            title: "SSH tab",
            titleOverride: nil,
            pwd: "/tmp/ignored-for-ssh",
            tabColor: .none,
            ssh: binding)

        let config = try #require(BaseTerminalController.reopenConfig(
            for: record,
            sshConfiguration: { binding, autoConnect in
                self.waitingConfiguration(for: binding, autoConnect: autoConnect, root: root)
            }))
        #expect(config.ssh?.binding == binding)
        #expect(config.ssh?.autoConnect == false)

        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: config, spawnsSurface: false)
        #expect(surface.sshStatus?.connection == .waiting)
    }
}
