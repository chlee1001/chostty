import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
struct SSHPaneBindingPropagationTests {
    private func launch(directory: URL) -> SSHPaneLaunch {
        SSHPaneLaunch(
            binding: SSHPaneBinding(
                reference: SSHHostReference(source: .sshConfig, alias: "prod"),
                displayDestination: "deploy@prod.example.com"),
            launchID: UUID(),
            runtimeDirectory: directory,
            autoConnect: false)
    }

    @Test func resolvedConfigPreservesSSHLaunch() {
        let launch = launch(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var config = Ghostty.SurfaceConfiguration()
        config.ssh = launch

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: nil,
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: config)
        #expect(resolved?.ssh == launch)
    }

    @Test func surfaceInitAttachesSSHChannelWithoutSpawningTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        var config = Ghostty.SurfaceConfiguration()
        config.ssh = launch(directory: root)

        let surface = Ghostty.SurfaceView(app, baseConfig: config, spawnsSurface: false)
        #expect(surface.sshChannel?.binding == config.ssh?.binding)
        #expect(surface.sshStatus?.connection == .waiting)
    }

    @Test func cConfigurationDoesNotCopySSHLaunchMetadata() {
        let c = ghostty_surface_config_s()
        #expect(Ghostty.SurfaceConfiguration(from: c).ssh == nil)
    }
}
