import Combine
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SSHTunnelEditorTests {
    @Test func savesLoopbackTunnelAndPublishesItToTheController() throws {
        try withTunnelFixture { fixture throws in
            fixture.model.beginNewTunnel()
            fixture.model.tunnelDraft = draft(host: fixture.reference, bindPort: "15432")
            fixture.model.saveTunnel()

            let saved = try SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels
            #expect(saved.count == 1)
            #expect(saved.first?.bindAddress == "127.0.0.1")
            #expect(saved.first?.externalBindConsent == nil)
            #expect(fixture.tunnels.definitions == saved)
            #expect(fixture.model.selection == .tunnel(try #require(saved.first).id))
        }
    }

    @Test func externalBindNeedsConsentAndCancelSavesNothing() throws {
        try withTunnelFixture { fixture throws in
            fixture.model.beginNewTunnel()
            var edited = draft(host: fixture.reference, bindPort: "8080")
            edited.bindAddress = "0.0.0.0"
            fixture.model.tunnelDraft = edited
            fixture.model.saveTunnel()

            #expect(fixture.model.needsBindConsent)
            fixture.model.dismissBindConsent()
            #expect(!fixture.model.needsBindConsent)
            #expect(try SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels.isEmpty)
            #expect(fixture.tunnels.definitions.isEmpty)
            #expect(fixture.model.tunnelDraft?.id == nil)
        }
    }

    @Test func grantedConsentIsStoredForTheExactBind() throws {
        try withTunnelFixture { fixture throws in
            fixture.model.beginNewTunnel()
            var edited = draft(host: fixture.reference, bindPort: "8080")
            edited.bindAddress = "0.0.0.0"
            fixture.model.tunnelDraft = edited
            fixture.model.saveTunnel()
            fixture.model.confirmBindConsent()

            let saved = try #require(SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels.first)
            let consent = try #require(saved.externalBindConsent)
            #expect(consent.matches(address: "0.0.0.0", port: 8080, kind: .local))

            // Changing the port invalidates the consent and asks again.
            var changed = try #require(fixture.model.tunnelDraft)
            changed.bindPort = "8081"
            fixture.model.tunnelDraft = changed
            fixture.model.saveTunnel()
            #expect(fixture.model.needsBindConsent)
            #expect(try SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels.first?.bindPort == 8080)
        }
    }

    @Test func runningTunnelCannotBeEditedOrDeleted() throws {
        try withTunnelFixture { fixture throws in
            fixture.model.beginNewTunnel()
            fixture.model.tunnelDraft = draft(host: fixture.reference, bindPort: "15432")
            fixture.model.saveTunnel()
            let id = try #require(fixture.model.tunnelDraft?.id)

            fixture.tunnels.start(id)
            #expect(fixture.model.selectedTunnelIsRunning)
            #expect(!fixture.model.canSaveTunnel)
            #expect(!fixture.model.canDeleteTunnel)
            fixture.model.deleteSelectedTunnel()
            #expect(fixture.model.errorMessage == "Stop the tunnel before deleting it.")
            #expect(try SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels.count == 1)

            #expect(fixture.tunnels.stopNow([id]))
            fixture.model.deleteSelectedTunnel()
            #expect(try SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels.isEmpty)
            #expect(fixture.model.tunnelDraft == nil)
        }
    }

    @Test func deletingAHostStopsItsTunnelsAndDropsTheirDefinitions() throws {
        try withTunnelFixture { fixture throws in
            fixture.model.beginNewTunnel()
            fixture.model.tunnelDraft = draft(host: fixture.reference, bindPort: "15432")
            fixture.model.saveTunnel()
            let id = try #require(fixture.model.tunnelDraft?.id)
            fixture.tunnels.start(id)

            fixture.model.selectManaged(fixture.host)
            #expect(fixture.model.selectedHostRunningTunnelCount == 1)
            fixture.model.deleteSelected()

            #expect(!fixture.tunnels.isRunning(id))
            #expect(fixture.tunnels.manager.phase(for: id) == .stopped)
            #expect(try SSHManagedHostStore(paths: fixture.paths).load().hosts.isEmpty)
            #expect(try SSHHostMetadataStore(paths: fixture.paths).load().metadata.tunnels.isEmpty)
            #expect(fixture.tunnels.definitions.isEmpty)
        }
    }

    @Test func keychainHostTunnelsAreNotBlocked() throws {
        try withTunnelFixture { fixture throws in
            fixture.model.beginNewTunnel()
            fixture.model.tunnelDraft = draft(host: fixture.reference, bindPort: "15432")
            fixture.model.saveTunnel()
            let definition = try #require(fixture.tunnels.definitions.first)
            #expect(fixture.tunnels.startBlocker(for: definition) == nil)

            let metadataStore = SSHHostMetadataStore(paths: fixture.paths)
            let snapshot = try metadataStore.load()
            let metadata = try SSHHostMetadataFile(
                hosts: [fixture.host.hostID: try SSHManagedHostMetadata(auth: .keychain)],
                favorites: [],
                tunnels: snapshot.metadata.tunnels)
            fixture.tunnels.apply(metadata)

            #expect(fixture.tunnels.startBlocker(for: definition) == nil)
        }
    }

    @Test func tunnelWhoseHostDisappearedCannotStart() throws {
        try withTunnelFixture { fixture throws in
            var definition = SSHTunnelDefinition(
                id: UUID(),
                name: "gone",
                host: SSHHostReference(source: .managed(hostID: UUID()), alias: "gone"),
                kind: .dynamic,
                bindPort: 1080)
            definition.bindAddress = "127.0.0.1"
            fixture.tunnels.apply(try SSHHostMetadataFile(tunnels: [definition]))

            #expect(fixture.tunnels.startBlocker(for: definition) == SSHTunnelController.missingHostMessage)
            fixture.tunnels.start(definition.id)
            #expect(!fixture.tunnels.isRunning(definition.id))
        }
    }

    @Test func statusTextMatchesTheDisplayedTunnelStates() {
        #expect(SSHTunnelController.status(for: .ready) == "ready")
        #expect(SSHTunnelController.status(for: .runningUnconfirmed) == "running, unconfirmed")
        #expect(SSHTunnelController.status(for: .authenticating) == "waiting for authentication")
        #expect(SSHTunnelStatusColor.color(for: .authenticating) == .gray)
        #expect(SSHTunnelController.status(for: .failed(.localPortInUse)) == SSHTunnelFailure.localPortInUse.message)
    }
}

// MARK: - Fixture

@MainActor
private struct TunnelFixture {
    let root: URL
    let paths: SSHPaths
    let host: SSHManagedHost
    let reference: SSHHostReference
    let tunnels: SSHTunnelController
    let model: SSHHostsEditorModel
}

private func draft(host: SSHHostReference, bindPort: String) -> SSHTunnelDraft {
    var draft = SSHTunnelDraft()
    draft.name = "database"
    draft.host = host
    draft.kind = .local
    draft.bindPort = bindPort
    draft.targetHost = "localhost"
    draft.targetPort = "5432"
    return draft
}

@MainActor
private func withTunnelFixture(_ body: (TunnelFixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = SSHPaths(
        home: root,
        runtimeRoot: root.appendingPathComponent("runtime"),
        environment: ["CHOSTTY_SSH_DATA_DIR": root.appendingPathComponent("data").path])
    try FileManager.default.createDirectory(at: paths.runtimeRoot, withIntermediateDirectories: true)
    let host = try SSHManagedHost(hostID: UUID(), alias: "db", hostName: "db.example.test")
    let store = SSHManagedHostStore(paths: paths)
    _ = try store.save(host, expectedHash: try store.load().hash)
    let catalog = SSHHostCatalog(paths: paths)
    catalog.refreshIfStale()
    let reference = SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias)
    // The launch factory always fails, so no test here ever spawns a process.
    let manager = SSHTunnelManager(
        runtimeRoot: paths.runtimeRoot,
        login: { SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil) },
        makeLaunch: { _, _, _, _ in throw CocoaError(.fileNoSuchFile) })
    let tunnels = SSHTunnelController(manager: manager, availableHosts: { [reference] })
    let model = SSHHostsEditorModel(
        paths: paths,
        store: store,
        metadata: SSHHostMetadataStore(paths: paths),
        catalog: catalog,
        resolver: TunnelFakeResolver(),
        secretStore: TunnelFakeSecretStore(),
        tunnels: tunnels,
        passwordWarnings: Empty<[UUID: String], Never>().eraseToAnyPublisher(),
        clearPasswordWarning: { _ in },
        connect: { _ in false })
    try body(TunnelFixture(
        root: root,
        paths: paths,
        host: host,
        reference: reference,
        tunnels: tunnels,
        model: model))
}

private final class TunnelFakeResolver: SSHResolving, @unchecked Sendable {
    func resolve(
        reference: SSHHostReference,
        paths: SSHPaths,
        observations: [String: SSHFileObservation],
        containsMatchExec: Bool,
        reason: SSHResolver.Reason,
        completion: @escaping @Sendable (SSHResolver.Result?) -> Void
    ) {
        completion(nil)
    }

    func resolveBaseline(alias: String, completion: @escaping @Sendable (SSHResolver.Result?) -> Void) {
        completion(nil)
    }
}

private final class TunnelFakeSecretStore: SSHSecretStore, @unchecked Sendable {
    func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer {
        throw SSHSecretStoreError.notFound
    }

    func target(for hostID: UUID) throws -> SSHTargetFingerprint {
        throw SSHSecretStoreError.notFound
    }

    func setPassword(_ secret: SSHSecretBuffer, for hostID: UUID, target: SSHTargetFingerprint, label: String) throws {}

    func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws {}

    func deletePassword(for hostID: UUID) throws {
        throw SSHSecretStoreError.notFound
    }
}
