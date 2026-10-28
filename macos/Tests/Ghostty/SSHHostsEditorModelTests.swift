import Combine
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SSHHostsEditorModelTests {
    @Test func rejectsAliasAlreadyDefinedInAnotherConfigFile() throws {
        try withEditorFixture { root, paths, catalog, model in
            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Host existing\n    HostName config.example.test\n".write(
                to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()

            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "existing", hostName: "managed.example.test")
            model.save()

            #expect(!FileManager.default.fileExists(atPath: paths.managedHostsFile.path))
            #expect(model.errorMessage != nil)
        }
    }

    @Test func jumpHostPickerOffersOtherHostsAndComposesCustomFields() throws {
        try withEditorFixture { root, paths, catalog, model in
            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Host bastion\n    HostName bastion.example.test\n".write(
                to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5")

            #expect(model.jumpHostChoices == ["bastion"])
            #expect(model.jumpHostChoice == .none)
            model.jumpHostChoiceBinding.wrappedValue = .host("bastion")
            #expect(model.draft?.proxyJump == "bastion")
            #expect(model.jumpHostChoice == .host("bastion"))

            model.jumpHostChoiceBinding.wrappedValue = .none
            model.jumpHostChoiceBinding.wrappedValue = .custom
            #expect(model.jumpHostChoice == .custom)
            model.jumpHopBinding(\.user).wrappedValue = "ubuntu"
            #expect(model.draft?.proxyJump == "ubuntu@")
            model.jumpHopBinding(\.host).wrappedValue = "192.168.219.219"
            model.jumpHopBinding(\.port).wrappedValue = "2222"
            #expect(model.draft?.proxyJump == "ubuntu@192.168.219.219:2222")
            #expect(model.jumpHopBinding(\.user).wrappedValue == "ubuntu")

            model.save()
            #expect(try SSHManagedHostStore(paths: paths).load().hosts.first?.proxyJump == "ubuntu@192.168.219.219:2222")
        }
    }

    @Test func refusesToSaveAJumpHostWithoutAHostName() throws {
        try withEditorFixture { _, paths, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5")
            model.jumpHostChoiceBinding.wrappedValue = .custom
            model.jumpHopBinding(\.user).wrappedValue = "ubuntu"

            model.save()

            #expect(model.errorMessage == SSHHostsEditorError.invalidProxyJump.errorDescription)
            #expect(!FileManager.default.fileExists(atPath: paths.managedHostsFile.path))
        }
    }

    @Test func checksTheJumpHostAsEnteredAndHidesAStaleResult() async throws {
        let checker = EditorFakeJumpHostChecker()
        try await withEditorFixture(jumpHostChecker: checker) { root, paths, catalog, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5", proxyJump: "ubuntu@gate:22")
            #expect(model.canCheckJumpHost)

            model.checkJumpHost()
            #expect(!model.canCheckJumpHost)
            #expect(model.currentJumpHostCheck == SSHJumpHostCheckState(proxyJump: "ubuntu@gate:22", result: nil))
            #expect(checker.checked.map(\.0) == ["ubuntu@gate:22"])
            // No hosts file yet, so ssh reads its default configuration.
            #expect(checker.checked.first?.1 == nil)

            checker.finish(.signedIn("ubuntu@gate:22"))
            let finished = SSHJumpHostCheckState(proxyJump: "ubuntu@gate:22", result: .signedIn("ubuntu@gate:22"))
            for _ in 0..<100 where model.currentJumpHostCheck != finished {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(model.currentJumpHostCheck == finished)

            model.jumpHopBinding(\.user).wrappedValue = "root"
            #expect(model.currentJumpHostCheck == nil)
            #expect(model.canCheckJumpHost)

            // A result for a value the user has since edited is not shown.
            model.checkJumpHost()
            model.jumpHopBinding(\.user).wrappedValue = "admin"
            checker.finish(.signedIn("root@gate:22"))
            let stale = SSHJumpHostCheckState(proxyJump: "root@gate:22", result: .signedIn("root@gate:22"))
            for _ in 0..<100 where model.jumpHostCheck != stale {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(model.jumpHostCheck == stale)
            #expect(model.currentJumpHostCheck == nil)
            #expect(model.canCheckJumpHost)

            model.beginNewHost()
            #expect(model.jumpHostCheck == nil)

            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Host deploy\n    HostName deploy.example.test\n".write(
                to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            let entry = try #require(catalog.snapshot.entries.first { $0.reference.alias == "deploy" })
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5", proxyJump: "gate")
            model.checkJumpHost()
            #expect(model.jumpHostCheck != nil)
            model.selectReadOnly(entry)
            #expect(model.jumpHostCheck == nil)
        }
    }

    @Test func aSlowerEarlierCheckDoesNotOverwriteANewerOne() async throws {
        let checker = EditorFakeJumpHostChecker()
        try await withEditorFixture(jumpHostChecker: checker) { _, _, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5", proxyJump: "qa@gate:22")
            model.checkJumpHost()
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5", proxyJump: "qa@gate:22")
            model.checkJumpHost()
            #expect(checker.checked.count == 2)

            let pending = SSHJumpHostCheckState(proxyJump: "qa@gate:22", result: nil)
            checker.finish(.unreachable("qa@gate:22", reason: "timed out"))
            for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(model.currentJumpHostCheck == pending)

            checker.finish(.signedIn("qa@gate:22"))
            let finished = SSHJumpHostCheckState(proxyJump: "qa@gate:22", result: .signedIn("qa@gate:22"))
            for _ in 0..<100 where model.currentJumpHostCheck != finished {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(model.currentJumpHostCheck == finished)
        }
    }

    @Test func jumpHostCheckAsksForMatchExecConsentAndChecksOnlyOneHop() throws {
        let checker = EditorFakeJumpHostChecker()
        try withEditorFixture(jumpHostChecker: checker) { root, paths, catalog, model in
            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Match exec true\n    User qa\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            #expect(catalog.snapshot.containsMatchExec)
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5", proxyJump: "first,second")
            #expect(!model.canCheckJumpHost)
            model.checkJumpHost()
            #expect(checker.checked.isEmpty)

            model.jumpHostChoiceBinding.wrappedValue = .custom
            model.draft?.proxyJump = "gate"
            model.checkJumpHost()
            #expect(model.needsMatchExecConsent)
            #expect(checker.checked.isEmpty)
            model.dismissMatchExecConsent()
            #expect(checker.checked.isEmpty)

            model.checkJumpHost()
            model.confirmMatchExecConsent()
            #expect(checker.checked.map(\.0) == ["gate"])
            #expect(checker.allowedMatchExec == [true])
        }
    }

    @Test func jumpHostFieldsKeepTheValueWellFormed() {
        var hop = SSHProxyJumpHop()
        SSHHostsEditorModel.setHopField(\.host, to: "1.2.3.4:2222", in: &hop)
        #expect(hop == SSHProxyJumpHop(host: "1.2.3.4", port: "2222"))
        SSHHostsEditorModel.setHopField(\.user, to: "ub@un,tu", in: &hop)
        #expect(hop.user == "ubuntu")
        SSHHostsEditorModel.setHopField(\.port, to: "22:", in: &hop)
        #expect(hop.port == "22")
        SSHHostsEditorModel.setHopField(\.host, to: "fe80::1", in: &hop)
        #expect(hop.value == "ubuntu@[fe80::1]:22")
        SSHHostsEditorModel.setHopField(\.host, to: "gate:", in: &hop)
        #expect(hop.host == "gate:")
        #expect(SSHProxyJumpHop(parsing: hop.value) == hop)

        // A whole hop pasted into HostName fills every field.
        var pasted = SSHProxyJumpHop()
        SSHHostsEditorModel.setHopField(\.host, to: " jump@10.0.0.1:2200\n", in: &pasted)
        #expect(pasted == SSHProxyJumpHop(user: "jump", host: "10.0.0.1", port: "2200"))
        SSHHostsEditorModel.setHopField(\.host, to: "[fe80::2]:22", in: &pasted)
        #expect(pasted == SSHProxyJumpHop(user: "jump", host: "fe80::2", port: "22"))
        SSHHostsEditorModel.setHopField(\.host, to: "ssh://ops@gate", in: &pasted)
        #expect(pasted == SSHProxyJumpHop(user: "ops", host: "gate", port: "22"))
        // An invalid hop is filtered like any typed value.
        SSHHostsEditorModel.setHopField(\.host, to: "@gate", in: &pasted)
        #expect(pasted.host == "gate")
    }

    @Test func choosingAnIdentityFileWritesAHomeRelativePath() throws {
        try withEditorFixture { _, _, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "inner", hostName: "10.0.0.5")
            model.addIdentityFile()

            model.setIdentityFile(URL(fileURLWithPath: "/Users/qa/.ssh/id_ed25519"), at: 0, home: "/Users/qa")
            #expect(model.draft?.identityFiles == ["~/.ssh/id_ed25519"])

            model.setIdentityFile(URL(fileURLWithPath: "/opt/keys/deploy"), at: 0, home: "/Users/qa")
            #expect(model.draft?.identityFiles == ["/opt/keys/deploy"])
            #expect(model.errorMessage == nil)

            model.setIdentityFile(URL(fileURLWithPath: "/Users/qa/My Keys/id"), at: 0, home: "/Users/qa")
            #expect(model.draft?.identityFiles == ["/opt/keys/deploy"])
            #expect(model.errorMessage != nil)

            model.setIdentityFile(URL(fileURLWithPath: "/Users/qa/.ssh/id_ed25519.pub"), at: 0, home: "/Users/qa")
            #expect(model.draft?.identityFiles == ["/opt/keys/deploy"])

            #expect(model.errorMessage != nil)
            // A successful choice clears the earlier refusal.
            model.setIdentityFile(URL(fileURLWithPath: "/opt/keys/100%key"), at: 0, home: "/Users/qa")
            #expect(model.draft?.identityFiles == ["/opt/keys/100%%key"])
            #expect(model.errorMessage == nil)
        }
        #expect(SSHHostsEditorModel.identityFilePath("/Users/qab/key", home: "/Users/qa") == "/Users/qab/key")
    }

    @Test func deletingSelectedManagedHostClearsTheSelection() throws {
        try withEditorFixture { _, paths, _, model in
            let store = SSHManagedHostStore(paths: paths)
            let initial = try store.load()
            let host = try SSHManagedHost(hostID: UUID(), alias: "build", hostName: "build.example.test")
            _ = try store.save(host, expectedHash: initial.hash)
            model.reload()

            model.selectManaged(host)
            model.deleteSelected()

            #expect(model.selection == nil)
            #expect(model.managedHosts.isEmpty)
            #expect(try store.load().hosts.isEmpty)
        }
    }

    @Test func connectsTheCatalogReferenceSelectedByTheUser() throws {
        try withEditorFixture { root, paths, catalog, _ in
            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Host deploy\n    HostName deploy.example.test\n".write(
                to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            let entry = try #require(catalog.snapshot.entries.first { $0.reference.alias == "deploy" })
            var connected: SSHHostReference?
            let model = SSHHostsEditorModel(
                paths: paths,
                store: SSHManagedHostStore(paths: paths),
                metadata: SSHHostMetadataStore(paths: paths),
                catalog: catalog,
                resolver: EditorFakeResolver(),
                secretStore: EditorFakeSecretStore(),
                passwordWarnings: Empty<[UUID: String], Never>().eraseToAnyPublisher(),
                clearPasswordWarning: { _ in },
                connect: { reference in
                    connected = reference
                    return true
                })

            model.selectReadOnly(entry)
            model.connectSelected()

            #expect(connected == entry.reference)
        }
    }

    @Test func detectsHashConflictsAndOverwritesOnlyAfterAnExplicitChoice() throws {
        try withEditorFixture { _, paths, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "db", hostName: "before.example.test")
            model.save()
            let host = try #require(model.managedHosts.first)
            model.selectManaged(host)
            var draft = try #require(model.draft)
            draft.hostName = "after.example.test"
            model.draft = draft

            let disk = try Data(contentsOf: paths.managedHostsFile)
            var external = Data("# changed outside Chostty\n".utf8)
            external.append(disk)
            try external.write(to: paths.managedHostsFile)
            model.save()

            #expect(model.changedOnDisk)
            #expect(try SSHManagedHostStore(paths: paths).load().hosts.first?.hostName == "before.example.test")

            model.save(overwritingExternalChanges: true)

            #expect(!model.changedOnDisk)
            #expect(try SSHManagedHostStore(paths: paths).load().hosts.first?.hostName == "after.example.test")
        }
    }

    @Test func aReadOnlySourceCannotBeSavedAsThoughItWereManaged() throws {
        try withEditorFixture { root, paths, catalog, model in
            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Host readonly\n    HostName readonly.example.test\n".write(
                to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            let entry = try #require(catalog.snapshot.entries.first)

            model.selectReadOnly(entry)
            model.save()

            #expect(!FileManager.default.fileExists(atPath: paths.managedHostsFile.path))
            #expect(model.errorMessage != nil)
        }
    }

    @Test func persistsDisplayNamesAndFavoritesWithoutCredentialStorage() throws {
        try withEditorFixture { root, paths, catalog, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "build", hostName: "build.example.test", displayName: "Build host")
            model.save()
            let host = try #require(model.managedHosts.first)
            let managedReference = SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias)

            let sshDirectory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
            try "Host source\n    HostName source.example.test\n".write(
                to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            let source = try #require(catalog.snapshot.entries.first { $0.reference.alias == "source" })
            model.setFavorite(true, for: source.reference)

            let metadata = try SSHHostMetadataStore(paths: paths).load().metadata
            #expect(metadata.hosts[host.hostID]?.displayName == "Build host")
            #expect(metadata.hosts[host.hostID]?.auth == .sshConfig)
            #expect(metadata.favorites.contains(source.reference))
            #expect(model.isFavorite(source.reference))
            #expect(!metadata.favorites.contains(managedReference))
        }
    }

    @Test func invalidNewDraftDoesNotCreateAHostsFile() throws {
        try withEditorFixture { _, paths, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(alias: "bad alias", hostName: "")
            model.save()

            #expect(!FileManager.default.fileExists(atPath: paths.managedHostsFile.path))
        }
    }

    @Test func malformedMetadataRejectsSavesFavoritesAndDeletesWithoutChangingFiles() throws {
        try withEditorFixture { _, paths, _, model in
            let store = SSHManagedHostStore(paths: paths)
            let host = try SSHManagedHost(hostID: UUID(), alias: "build", hostName: "build.example.test")
            let initial = try store.load()
            _ = try store.save(host, expectedHash: initial.hash)
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            let malformed = Data("{ not JSON".utf8)
            try malformed.write(to: paths.metadataFile)

            model.reload()
            let hostsBefore = try Data(contentsOf: paths.managedHostsFile)
            let metadataBefore = try Data(contentsOf: paths.metadataFile)
            model.selectManaged(host)
            model.save()
            model.setFavorite(true, for: SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias))
            model.deleteSelected()

            #expect(model.metadataSnapshot == nil)
            #expect(try Data(contentsOf: paths.managedHostsFile) == hostsBefore)
            #expect(try Data(contentsOf: paths.metadataFile) == metadataBefore)
            #expect(model.errorMessage != nil)
        }
    }

    @Test func reloadRecoversAfterAnInitiallyUnavailableMetadataSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SSHPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": root.appendingPathComponent("data").path])
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        try Data("{ not JSON".utf8).write(to: paths.metadataFile)
        let model = SSHHostsEditorModel(
            paths: paths,
            store: SSHManagedHostStore(paths: paths),
            metadata: SSHHostMetadataStore(paths: paths),
            catalog: SSHHostCatalog(paths: paths),
            resolver: EditorFakeResolver(),
            secretStore: EditorFakeSecretStore(),
            passwordWarnings: Empty<[UUID: String], Never>().eraseToAnyPublisher(),
            clearPasswordWarning: { _ in },
            connect: { _ in false })

        #expect(model.metadataSnapshot == nil)

        let metadata = try SSHHostMetadataFile()
        try JSONEncoder().encode(metadata).write(to: paths.metadataFile)
        model.reload()

        #expect(model.metadataSnapshot?.metadata == metadata)
        #expect(model.errorMessage == nil)
    }

    @Test func keychainAuthRoundTripsWithoutWritingPasswordToConfigOrMetadata() throws {
        try withEditorFixture { _, paths, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(
                alias: "keychain",
                hostName: "keychain.example.test",
                user: "deploy",
                port: "2201",
                auth: .keychain)
            model.save()

            let host = try #require(model.managedHosts.first)
            let reference = SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias)
            model.setFavorite(true, for: reference)
            let metadata = try SSHHostMetadataStore(paths: paths).load().metadata
            let config = try String(contentsOf: paths.managedHostsFile, encoding: .utf8)
            let serialized = try JSONEncoder().encode(metadata)
            let metadataJSON = try #require(String(data: serialized, encoding: .utf8))
            #expect(metadata.hosts[host.hostID]?.auth == .keychain)
            #expect(metadata.favorites.contains(reference))
            #expect(!config.contains("password"))
            #expect(!metadataJSON.contains("password"))
        }
    }

    @Test func ineligibleKeychainModeDoesNotMutateEitherFile() throws {
        try withEditorFixture { _, paths, _, model in
            model.beginNewHost()
            model.draft = SSHHostDraft(
                alias: "missing-port",
                hostName: "host.example.test",
                user: "deploy",
                auth: .keychain)
            model.save()

            #expect(!FileManager.default.fileExists(atPath: paths.managedHostsFile.path))
            #expect(!FileManager.default.fileExists(atPath: paths.metadataFile.path))
            #expect(model.errorMessage?.contains("Port") == true)
        }
    }

    @Test func displaysPublishedRuntimePasswordWarningsForTheSelectedHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SSHPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": root.appendingPathComponent("data").path])
        let store = SSHManagedHostStore(paths: paths)
        let host = try SSHManagedHost(hostID: UUID(), alias: "warning", hostName: "warning.example.test")
        let initial = try store.load()
        _ = try store.save(host, expectedHash: initial.hash)
        let warnings = CurrentValueSubject<[UUID: String], Never>([:])
        let model = SSHHostsEditorModel(
            paths: paths,
            store: store,
            metadata: SSHHostMetadataStore(paths: paths),
            catalog: SSHHostCatalog(paths: paths),
            resolver: EditorFakeResolver(),
            secretStore: EditorFakeSecretStore(),
            passwordWarnings: warnings.eraseToAnyPublisher(),
            clearPasswordWarning: { _ in },
            connect: { _ in false })

        model.selectManaged(host)
        var publicationCount = 0
        let publication = model.objectWillChange.sink { _ in publicationCount += 1 }
        warnings.send([host.hostID: "Saved password was rejected."])

        #expect(model.passwordWarning == "Saved password was rejected.")
        #expect(publicationCount > 0)
        publication.cancel()
    }

    @Test func savesAndRemovesPasswordsOnlyForSavedEligibleKeychainHosts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SSHPaths(
            home: root,
            runtimeRoot: root.appendingPathComponent("runtime"),
            environment: ["CHOSTTY_SSH_DATA_DIR": root.appendingPathComponent("data").path])
        let host = try SSHManagedHost(
            hostID: UUID(),
            alias: "eligible",
            hostName: "eligible.example.test",
            user: "deploy",
            port: 2201)
        let managedStore = SSHManagedHostStore(paths: paths)
        let managedInitial = try managedStore.load()
        _ = try managedStore.save(host, expectedHash: managedInitial.hash)
        let metadataStore = SSHHostMetadataStore(paths: paths)
        let metadataInitial = try metadataStore.load()
        _ = try metadataStore.save(
            SSHHostMetadataFile(hosts: [host.hostID: try SSHManagedHostMetadata(auth: .keychain)]),
            expectedHash: metadataInitial.hash)
        let secretStore = EditorFakeSecretStore()
        let model = SSHHostsEditorModel(
            paths: paths,
            store: managedStore,
            metadata: metadataStore,
            catalog: SSHHostCatalog(paths: paths),
            resolver: EditorFakeResolver(),
            secretStore: secretStore,
            passwordWarnings: Empty<[UUID: String], Never>().eraseToAnyPublisher(),
            clearPasswordWarning: { _ in },
            connect: { _ in false })
        model.selectManaged(host)
        let bytes = Data([1, 2, 3])
        model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })

        #expect(secretStore.setCount == 1)

        model.removePassword()

        #expect(secretStore.deleteCount == 1)
    }

    @Test func passwordSubmissionOnlyReachesTheStoreAndWipesTheInputBuffer() throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectManaged(fixture.host)
        let hostsBefore = try Data(contentsOf: fixture.paths.managedHostsFile)
        let metadataBefore = try Data(contentsOf: fixture.paths.metadataFile)
        let synthetic = Array("chostty-test-only-\(UUID().uuidString)".utf8)
        let secret = synthetic.withUnsafeBytes { SSHSecretBuffer(copying: $0) }

        fixture.model.savePassword(secret)

        #expect(fixture.secretStore.savedBytes(for: fixture.host.hostID) == synthetic)
        #expect(secret.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
        #expect(try Data(contentsOf: fixture.paths.managedHostsFile) == hostsBefore)
        #expect(try Data(contentsOf: fixture.paths.metadataFile) == metadataBefore)
        #expect(fixture.secretStore.passwordReadCount == 0)
    }

    @Test func confirmsTargetWithoutReadingPasswordAndAllowsAliasButNotEndpointChanges() throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldTarget = try SSHTargetFingerprint(
            hostID: fixture.host.hostID,
            user: "deploy",
            hostName: "old.example.test",
            port: 2201)
        fixture.secretStore.setTarget(oldTarget, for: fixture.host.hostID)

        fixture.model.selectManaged(fixture.host)
        fixture.model.confirmPasswordTarget()

        #expect(fixture.secretStore.updateCount == 1)
        #expect(fixture.secretStore.passwordReadCount == 0)

        var aliasOnly = try #require(fixture.model.draft)
        aliasOnly.alias = "renamed"
        fixture.model.draft = aliasOnly
        let bytes = Data([1])
        fixture.model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
        #expect(fixture.secretStore.setCount == 1)

        var endpointChanged = try #require(fixture.model.draft)
        endpointChanged.hostName = "changed.example.test"
        fixture.model.draft = endpointChanged
        fixture.model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
        #expect(fixture.secretStore.setCount == 1)
        #expect(fixture.model.errorMessage?.contains("Save host changes") == true)
    }

    @Test func rejectsCredentialMutationAfterMetadataOrHostHashChanges() throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectManaged(fixture.host)
        try Data("{ invalid".utf8).write(to: fixture.paths.metadataFile)
        fixture.model.reload()
        let bytes = Data([1])
        fixture.model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
        #expect(fixture.secretStore.setCount == 0)

        let metadata = try SSHHostMetadataFile(
            hosts: [fixture.host.hostID: try SSHManagedHostMetadata(auth: .keychain)])
        try JSONEncoder().encode(metadata).write(to: fixture.paths.metadataFile)
        fixture.model.reload()
        fixture.model.selectManaged(fixture.host)
        var outsideChange = try Data(contentsOf: fixture.paths.managedHostsFile)
        outsideChange.append(Data("# external\n".utf8))
        try outsideChange.write(to: fixture.paths.managedHostsFile)
        fixture.model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
        #expect(fixture.secretStore.setCount == 0)
        #expect(fixture.model.changedOnDisk)
    }

    @Test func reportsPasswordDeletionFailureAfterDeletingTheHost() throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.secretStore.deleteError = .denied
        fixture.model.selectManaged(fixture.host)
        fixture.model.deleteSelected()

        #expect(fixture.model.managedHosts.isEmpty)
        #expect(fixture.model.partialSave)
        #expect(fixture.model.errorMessage?.contains("saved password") == true)
    }

    @Test func refusesCredentialMutationForReadOnlyEntries() throws {
        try withEditorFixture { root, paths, catalog, model in
            let directory = root.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "Host readonly\n    HostName readonly.example.test\n".write(
                to: paths.userConfig,
                atomically: true,
                encoding: .utf8)
            catalog.refreshIfStale()
            model.selectReadOnly(try #require(catalog.snapshot.entries.first))
            let bytes = Data([1])
            model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
            #expect(model.errorMessage?.contains("Save this host") == true)
        }
    }

    @Test func refusesCredentialMutationsWhenSavedIncludePrecedesEndpointFields() throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let include = fixture.root.appendingPathComponent("endpoint.conf")
        try "Port 2202\n".write(to: include, atomically: false, encoding: .utf8)
        let source = """
        # chostty-host-id: \(fixture.host.hostID.uuidString)
        Host \(fixture.host.alias)
            Include \(include.path)
            User deploy
            HostName \(fixture.host.hostName)
            Port 2201
        """
        try source.write(to: fixture.paths.managedHostsFile, atomically: false, encoding: .utf8)
        fixture.model.reload()
        fixture.model.selectManaged(try #require(fixture.model.managedHosts.first))
        let original = try Data(contentsOf: fixture.paths.managedHostsFile)
        let bytes = Data([1])

        #expect(!fixture.model.canManagePassword)
        #expect(fixture.model.keychainEligibilityDescription?.contains("Include") == true)
        fixture.model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
        fixture.model.confirmPasswordTarget()
        fixture.model.removePassword()

        #expect(fixture.secretStore.setCount == 0)
        #expect(fixture.secretStore.updateCount == 0)
        #expect(fixture.secretStore.deleteCount == 0)
        #expect(try Data(contentsOf: fixture.paths.managedHostsFile) == original)
    }

    @Test func canonicallyEquivalentUnsavedEndpointsStillRequireSaving() throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var host = fixture.host
        host.hostName = "café.example.test"
        let store = SSHManagedHostStore(paths: fixture.paths)
        _ = try store.save(host, expectedHash: store.load().hash)
        fixture.model.reload()
        fixture.model.selectManaged(host)
        var draft = try #require(fixture.model.draft)
        draft.hostName = "café.example.test"
        fixture.model.draft = draft
        let bytes = Data([1])

        #expect(!fixture.model.canManagePassword)
        fixture.model.savePassword(bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) })
        #expect(fixture.secretStore.setCount == 0)
        #expect(fixture.model.errorMessage?.contains("Save host changes") == true)
    }

    @Test func ignoresStaleAsynchronousPasswordStatusAfterSelectionChanges() async throws {
        let fixture = try eligibleKeychainFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let second = try SSHManagedHost(
            hostID: UUID(),
            alias: "second",
            hostName: "second.example.test",
            user: "deploy",
            port: 2202)
        let store = SSHManagedHostStore(paths: fixture.paths)
        let managedSnapshot = try store.load()
        _ = try store.save(second, expectedHash: managedSnapshot.hash)
        let metadataStore = SSHHostMetadataStore(paths: fixture.paths)
        let metadata = try metadataStore.load()
        _ = try metadataStore.save(
            SSHHostMetadataFile(
                hosts: [
                    fixture.host.hostID: try SSHManagedHostMetadata(auth: .keychain),
                    second.hostID: try SSHManagedHostMetadata(auth: .keychain),
                ]),
            expectedHash: metadata.hash)
        fixture.secretStore.setTarget(
            try SSHTargetFingerprint(
                hostID: fixture.host.hostID,
                user: "deploy",
                hostName: "old.example.test",
                port: 2201),
            for: fixture.host.hostID)
        fixture.secretStore.setTarget(
            try SSHTargetFingerprint(
                hostID: second.hostID,
                user: "deploy",
                hostName: second.hostName,
                port: 2202),
            for: second.hostID)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        fixture.secretStore.targetStarted = started
        fixture.secretStore.targetRelease = release
        fixture.model.reload()

        fixture.model.selectManaged(fixture.host)
        #expect(signaled(started))
        fixture.model.selectManaged(second)
        #expect(signaled(started))
        release.signal()
        release.signal()
        #expect(await waitFor { fixture.model.passwordStatus == .ready })
    }
}

/// Synchronous so the blocking wait stays out of the async test body.
private func signaled(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 1) == .success
}

@MainActor
private struct EligibleKeychainFixture {
    let root: URL
    let paths: SSHPaths
    let host: SSHManagedHost
    let model: SSHHostsEditorModel
    let secretStore: EditorFakeSecretStore
}

@MainActor
private func eligibleKeychainFixture() throws -> EligibleKeychainFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = SSHPaths(
        home: root,
        runtimeRoot: root.appendingPathComponent("runtime"),
        environment: ["CHOSTTY_SSH_DATA_DIR": root.appendingPathComponent("data").path])
    let host = try SSHManagedHost(
        hostID: UUID(),
        alias: "eligible",
        hostName: "eligible.example.test",
        user: "deploy",
        port: 2201)
    let managedStore = SSHManagedHostStore(paths: paths)
    let managedInitial = try managedStore.load()
    _ = try managedStore.save(host, expectedHash: managedInitial.hash)
    let metadataStore = SSHHostMetadataStore(paths: paths)
    let metadataInitial = try metadataStore.load()
    _ = try metadataStore.save(
        SSHHostMetadataFile(hosts: [host.hostID: try SSHManagedHostMetadata(auth: .keychain)]),
        expectedHash: metadataInitial.hash)
    let secretStore = EditorFakeSecretStore()
    let model = SSHHostsEditorModel(
        paths: paths,
        store: managedStore,
        metadata: metadataStore,
        catalog: SSHHostCatalog(paths: paths),
        resolver: EditorFakeResolver(),
        secretStore: secretStore,
        passwordWarnings: Empty<[UUID: String], Never>().eraseToAnyPublisher(),
        clearPasswordWarning: { _ in },
        connect: { _ in false })
    return EligibleKeychainFixture(
        root: root,
        paths: paths,
        host: host,
        model: model,
        secretStore: secretStore)
}

private final class EditorFakeJumpHostChecker: SSHJumpHostChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, URL?)] = []
    private var completions: [@Sendable (SSHJumpHostCheckResult) -> Void] = []

    var checked: [(String, URL?)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private var consents: [Bool] = []

    var allowedMatchExec: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return consents
    }

    func check(
        proxyJump: String,
        configFile: URL?,
        containsMatchExec: Bool,
        allowMatchExec: Bool,
        completion: @escaping @Sendable (SSHJumpHostCheckResult) -> Void
    ) {
        lock.lock()
        requests.append((proxyJump, configFile))
        consents.append(allowMatchExec)
        completions.append(completion)
        lock.unlock()
    }

    func finish(_ result: SSHJumpHostCheckResult) {
        lock.lock()
        let pending = completions.removeFirst()
        lock.unlock()
        pending(result)
    }
}

private final class EditorFakeResolver: SSHResolving, @unchecked Sendable {
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

private final class EditorFakeSecretStore: SSHSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [UUID: SSHTargetFingerprint] = [:]
    private var secrets: [UUID: [UInt8]] = [:]
    private var storedSetCount = 0
    private var storedDeleteCount = 0
    private var storedTargetReadCount = 0
    private var storedUpdateCount = 0
    private var storedPasswordReadCount = 0
    var deleteError: SSHSecretStoreError?
    var targetStarted: DispatchSemaphore?
    var targetRelease: DispatchSemaphore?

    var setCount: Int { lock.withLock { storedSetCount } }
    var deleteCount: Int { lock.withLock { storedDeleteCount } }
    var targetReadCount: Int { lock.withLock { storedTargetReadCount } }
    var updateCount: Int { lock.withLock { storedUpdateCount } }
    var passwordReadCount: Int { lock.withLock { storedPasswordReadCount } }

    func savedBytes(for hostID: UUID) -> [UInt8]? { lock.withLock { secrets[hostID] } }

    func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer {
        lock.withLock { storedPasswordReadCount += 1 }
        throw SSHSecretStoreError.notFound
    }

    func target(for hostID: UUID) throws -> SSHTargetFingerprint {
        let target = try lock.withLock {
            storedTargetReadCount += 1
            guard let target = targets[hostID] else { throw SSHSecretStoreError.notFound }
            return target
        }
        targetStarted?.signal()
        _ = targetRelease?.wait(timeout: .now() + 1)
        return target
    }

    func setPassword(
        _ secret: SSHSecretBuffer,
        for hostID: UUID,
        target: SSHTargetFingerprint,
        label: String
    ) throws {
        let copied = secret.withUnsafeBytes { Array($0) }
        lock.withLock {
            storedSetCount += 1
            targets[hostID] = target
            secrets[hostID] = copied
        }
    }

    func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws {
        try lock.withLock {
            guard targets[hostID] != nil else { throw SSHSecretStoreError.notFound }
            storedUpdateCount += 1
            targets[hostID] = target
        }
    }

    func deletePassword(for hostID: UUID) throws {
        if let deleteError { throw deleteError }
        lock.withLock {
            storedDeleteCount += 1
            targets.removeValue(forKey: hostID)
            secrets.removeValue(forKey: hostID)
        }
    }

    func setTarget(_ target: SSHTargetFingerprint, for hostID: UUID) {
        lock.withLock { targets[hostID] = target }
    }
}

@MainActor
private func withEditorFixture(
    jumpHostChecker: any SSHJumpHostChecking = SSHJumpHostChecker(sshURL: URL(fileURLWithPath: "/usr/bin/false")),
    _ body: (URL, SSHPaths, SSHHostCatalog, SSHHostsEditorModel) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, catalog, model) = try makeEditorFixture(root: root, jumpHostChecker: jumpHostChecker)
    try body(root, paths, catalog, model)
}

/// For tests that wait on a main-actor completion: a nested run loop cannot
/// run main-actor work while the test itself holds the main actor, so the
/// body suspends instead.
@MainActor
private func withEditorFixture(
    jumpHostChecker: any SSHJumpHostChecking,
    _ body: (URL, SSHPaths, SSHHostCatalog, SSHHostsEditorModel) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, catalog, model) = try makeEditorFixture(root: root, jumpHostChecker: jumpHostChecker)
    try await body(root, paths, catalog, model)
}

@MainActor
private func makeEditorFixture(
    root: URL,
    jumpHostChecker: any SSHJumpHostChecking
) throws -> (SSHPaths, SSHHostCatalog, SSHHostsEditorModel) {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = SSHPaths(
        home: root,
        runtimeRoot: root.appendingPathComponent("runtime"),
        environment: ["CHOSTTY_SSH_DATA_DIR": root.appendingPathComponent("data").path])
    let catalog = SSHHostCatalog(paths: paths)
    let model = SSHHostsEditorModel(
        paths: paths,
        store: SSHManagedHostStore(paths: paths),
        metadata: SSHHostMetadataStore(paths: paths),
        catalog: catalog,
        resolver: EditorFakeResolver(),
        jumpHostChecker: jumpHostChecker,
        secretStore: EditorFakeSecretStore(),
        passwordWarnings: Empty<[UUID: String], Never>().eraseToAnyPublisher(),
        clearPasswordWarning: { _ in },
        connect: { _ in false })
    return (paths, catalog, model)
}
