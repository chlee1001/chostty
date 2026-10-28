import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHCatalogFreshnessTests {
    @Test func reconnectRescansDeletedAliasWithoutAnOpenManagementWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config")
        let paths = SSHPaths(home: root, userConfig: config, systemConfig: root.appendingPathComponent("system"), runtimeRoot: root)
        let catalog = SSHHostCatalog(paths: paths)
        let reference = SSHHostReference(source: .sshConfig, alias: "prod")
        try "Host prod\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(catalog.revalidation(for: reference) == .valid)
        try "Host other\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(catalog.revalidation(for: reference) == .blocked(.hostRemoved))
        try FileManager.default.removeItem(at: config)
        #expect(catalog.revalidation(for: reference) == .blocked(.hostRemoved))
        try "Host prod\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(catalog.revalidation(for: reference) == .valid)
    }

    @Test func managedReferenceRejectsReplacementDeletionAndHostIDMutationThenRestores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SSHPaths(
            home: root,
            userConfig: root.appendingPathComponent("config"),
            systemConfig: root.appendingPathComponent("system"),
            runtimeRoot: root.appendingPathComponent("runtime"))
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        let hostID = UUID()
        let replacementID = UUID()
        let reference = SSHHostReference(source: .managed(hostID: hostID), alias: "prod")

        try managedConfig(hostID: hostID, alias: "prod").write(
            to: paths.managedHostsFile,
            atomically: true,
            encoding: .utf8)
        let catalog = SSHHostCatalog(paths: paths)
        #expect(catalog.revalidation(for: reference) == .valid)

        try managedConfig(hostID: replacementID, alias: "prod").write(
            to: paths.managedHostsFile,
            atomically: true,
            encoding: .utf8)
        #expect(catalog.revalidation(for: reference) == .blocked(.hostRemoved))

        try FileManager.default.removeItem(at: paths.managedHostsFile)
        #expect(catalog.revalidation(for: reference) == .blocked(.hostRemoved))

        try managedConfig(hostID: hostID, alias: "prod").write(
            to: paths.managedHostsFile,
            atomically: true,
            encoding: .utf8)
        #expect(catalog.revalidation(for: reference) == .valid)
    }

    @Test func removingManagedHostBlocksReconnectWithoutChangingLiveConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SSHPaths(
            home: root,
            userConfig: root.appendingPathComponent("config"),
            systemConfig: root.appendingPathComponent("system"),
            runtimeRoot: root.appendingPathComponent("runtime"))
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        let hostID = UUID()
        let reference = SSHHostReference(source: .managed(hostID: hostID), alias: "prod")
        try managedConfig(hostID: hostID, alias: "prod").write(
            to: paths.managedHostsFile,
            atomically: true,
            encoding: .utf8)

        let catalog = SSHHostCatalog(paths: paths)
        #expect(catalog.revalidation(for: reference) == .valid)
        let coordinator = SSHPaneCoordinator(catalog: catalog, authorization: nil, brokerAvailable: { false })
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let launch = SSHPaneLaunch(
            binding: SSHPaneBinding(reference: reference),
            launchID: UUID(),
            runtimeDirectory: root.appendingPathComponent("pane"),
            autoConnect: false)
        let channel = try #require(SSHPaneChannel.attach(launch, to: surface))
        coordinator.register(channel)
        surface.sshStatus = SSHPaneStatus(connection: .connected, reconnectBlock: nil)

        try FileManager.default.removeItem(at: paths.managedHostsFile)
        catalog.refreshIfStale()

        #expect(surface.sshStatus?.connection == .connected)
        #expect(surface.sshStatus?.reconnectBlock == .hostRemoved)
    }
}

private func managedConfig(hostID: UUID, alias: String) -> String {
    """
    # chostty-host-id: \(hostID.uuidString)
    Host \(alias)
        HostName example.test
    """
}
