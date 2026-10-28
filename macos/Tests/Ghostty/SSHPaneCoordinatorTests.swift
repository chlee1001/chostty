import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHPaneCoordinatorTests {
    @Test func duplicateRequestsProduceOneCommandAndDenyAllowsNewSequence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config")
        try "Host prod\n".write(to: config, atomically: true, encoding: .utf8)
        let paths = SSHPaths(home: root, userConfig: config, systemConfig: root.appendingPathComponent("absent"), runtimeRoot: root)
        let catalog = SSHHostCatalog(paths: paths)
        catalog.refreshIfStale()
        let coordinator = SSHPaneCoordinator(catalog: catalog, authorization: nil, brokerAvailable: { false })
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let launch = SSHPaneLaunch(
            binding: .init(reference: .init(source: .sshConfig, alias: "prod")),
            launchID: UUID(), runtimeDirectory: root.appendingPathComponent("pane"), autoConnect: false)
        let channel = try #require(SSHPaneChannel.attach(launch, to: surface))
        coordinator.register(channel)
        let reader = open(launch.runtimeDirectory.appendingPathComponent("control").path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        #expect(reader >= 0)
        defer { close(reader) }
        func commands() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(reader, &bytes, bytes.count)
            guard count > 0 else { return "" }
            return try #require(String(bytes: bytes.prefix(count), encoding: .utf8))
        }
        coordinator.requestConnect(launchID: launch.launchID)
        coordinator.requestConnect(launchID: launch.launchID)
        #expect(try commands() == "connect 1 -\n")
        #expect(try commands().isEmpty)

        let temporary = launch.runtimeDirectory.appendingPathComponent("state.tmp")
        try "exited 1 255 1\n".write(to: temporary, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: temporary, to: launch.runtimeDirectory.appendingPathComponent("state"))
        for _ in 0..<200 {
            if channel.lastStateSequence == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(channel.lastStateSequence == 1)
        try "".write(to: config, atomically: true, encoding: .utf8)
        catalog.refreshIfStale()
        #expect(surface.sshStatus?.connection == .lost(exitStatus: 255, everConnected: true))
        #expect(surface.sshStatus?.reconnectBlock == .hostRemoved)
        coordinator.requestConnect(launchID: launch.launchID)
        coordinator.requestConnect(launchID: launch.launchID)
        #expect(try commands() == "deny 2 hostRemoved\n")
        #expect(try commands().isEmpty)
        try "exited 2 255 1\n".write(to: temporary, atomically: false, encoding: .utf8)
        #expect(rename(temporary.path, launch.runtimeDirectory.appendingPathComponent("state").path) == 0)
        for _ in 0..<200 {
            if channel.lastStateSequence == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(channel.lastStateSequence == 2)
        try "Host prod\n".write(to: config, atomically: true, encoding: .utf8)
        try "connect-requested 2\n".write(to: temporary, atomically: false, encoding: .utf8)
        #expect(rename(temporary.path, launch.runtimeDirectory.appendingPathComponent("state").path) == 0)
        coordinator.requestConnect(launchID: launch.launchID)
        #expect(try commands() == "connect 3 -\n")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try commands().isEmpty)
        #expect(surface.sshStatus?.reconnectBlock == nil)
    }
}
