import Foundation
import Testing
@testable import Ghostty

struct SSHHostMetadataStoreTests {
    @Test func roundTripsMetadata() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let initial = try store.load()
            let hostID = UUID()
            let tunnel = localTunnel()
            let metadata = try SSHHostMetadataFile(
                hosts: [hostID: try SSHManagedHostMetadata(displayName: "Production database")],
                favorites: [SSHHostReference(source: .managed(hostID: hostID), alias: "db")],
                tunnels: [tunnel]
            )

            let saved = try store.save(metadata, expectedHash: initial.hash)
            let loaded = try store.load()

            #expect(saved.metadata == metadata)
            #expect(saved.hash == loaded.hash)
            #expect(loaded.metadata == metadata)
            #expect(loaded.hash != nil)
            #expect(permissions(of: paths.metadataFile) == 0o600)

            let json = try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: paths.metadataFile)) as? [String: Any])
            let hosts = try #require(json["hosts"] as? [String: Any])
            #expect(hosts[hostID.uuidString] != nil)
            let tunnels = try #require(json["tunnels"] as? [[String: Any]])
            #expect(tunnels.map { $0["id"] as? String } == [tunnel.id.uuidString])
        }
    }

    @Test func ignoresUnknownJSONKeysAndDefaultsMissingOptionalFields() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let id = UUID()
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            let source = """
            {
              "version": 1,
              "hosts": {
                "\(id.uuidString)": {
                  "displayName": "Build server",
                  "futureHostSetting": true
                }
              },
              "futureRootSetting": ["ignored"]
            }
            """
            try source.write(to: paths.metadataFile, atomically: true, encoding: .utf8)

            let loaded = try store.load()
            let expected = try SSHManagedHostMetadata(displayName: "Build server")

            #expect(loaded.metadata.hosts[id] == expected)
            #expect(loaded.metadata.favorites.isEmpty)
            #expect(loaded.metadata.tunnels.isEmpty)
        }
    }

    @Test func missingFileLoadsAnEmptySnapshotWithoutCreatingIt() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let loaded = try store.load()
            let expected = try SSHHostMetadataFile()

            #expect(loaded.metadata == expected)
            #expect(loaded.hash == nil)
            #expect(!FileManager.default.fileExists(atPath: paths.metadataFile.path))
        }
    }

    @Test func refusesAHashConflict() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let initial = try store.load()
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try "{\"version\":1,\"hosts\":{},\"favorites\":[]}".write(
                to: paths.metadataFile,
                atomically: true,
                encoding: .utf8
            )

            #expect(throws: SSHStoreError.changedOnDisk) {
                try store.save(SSHHostMetadataFile(), expectedHash: initial.hash)
            }
        }
    }

    @Test func injectedFailurePreservesTheOriginalFile() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let initial = try store.load()
            let original = try SSHHostMetadataFile(
                hosts: [UUID(): try SSHManagedHostMetadata(displayName: "Original")]
            )
            let saved = try store.save(original, expectedHash: initial.hash)
            let before = try Data(contentsOf: paths.metadataFile)
            let failingStore = SSHHostMetadataStore(
                paths: paths,
                writer: SSHSecureFileWriter(failurePoint: .beforeWrite)
            )

            #expect(throws: SSHStoreError.writeFailed(EIO)) {
                try failingStore.save(SSHHostMetadataFile(), expectedHash: saved.hash)
            }
            #expect(try Data(contentsOf: paths.metadataFile) == before)
            let names = try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path)
            #expect(!names.contains { $0.hasSuffix(".tmp") })
            #expect(permissions(of: paths.metadataFile) == 0o600)
        }
    }

    @Test func invalidJSONFailsWithoutOverwritingTheFile() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let invalid = Data("{ not json".utf8)
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try invalid.write(to: paths.metadataFile)

            #expect(throws: (any Error).self) {
                _ = try store.load()
            }
            #expect(throws: (any Error).self) {
                try store.save(SSHHostMetadataFile(), expectedHash: SSHSecureFileWriter.hash(of: invalid))
            }
            #expect(try Data(contentsOf: paths.metadataFile) == invalid)
        }
    }

    @Test func rejectsInvalidDisplayNames() {
        #expect(throws: SSHHostMetadataError.invalidDisplayName) {
            _ = try SSHManagedHostMetadata(displayName: "name\nHost injected")
        }
    }

    @Test func rejectsInvalidUUIDHostKeys() throws {
        let data = Data("""
        {
          "version": 1,
          "hosts": {
            "not-a-uuid": {}
          }
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SSHHostMetadataFile.self, from: data)
        }
    }

    @Test func rejectsInvalidTunnelDefinitionsWithoutOverwriting() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let initial = try store.load()
            let saved = try store.save(try SSHHostMetadataFile(tunnels: [localTunnel()]), expectedHash: initial.hash)
            let original = try Data(contentsOf: paths.metadataFile)
            var invalidTunnel = localTunnel()
            invalidTunnel.bindPort = 0

            #expect(throws: SSHTunnelDefinitionError.invalidBindPort) {
                try store.save(SSHHostMetadataFile(tunnels: [invalidTunnel]), expectedHash: saved.hash)
            }
            #expect(try Data(contentsOf: paths.metadataFile) == original)
        }
    }

    @Test func rejectsDuplicateTunnelIDsWithoutOverwriting() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let initial = try store.load()
            let saved = try store.save(try SSHHostMetadataFile(tunnels: [localTunnel()]), expectedHash: initial.hash)
            let original = try Data(contentsOf: paths.metadataFile)
            let duplicateID = UUID()
            let first = localTunnel(id: duplicateID)
            let second = localTunnel(id: duplicateID)

            #expect(throws: SSHHostMetadataError.duplicateTunnelID(duplicateID)) {
                try store.save(SSHHostMetadataFile(tunnels: [first, second]), expectedHash: saved.hash)
            }
            #expect(try Data(contentsOf: paths.metadataFile) == original)
        }
    }

    @Test func rejectsMalformedTunnelEntriesWithoutOverwriting() throws {
        try withTemporaryMetadataStore { _, paths, store in
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            let malformed = Data("""
            {
              "version": 1,
              "tunnels": [{
                "id": "\(UUID().uuidString)",
                "name": "Bad",
                "host": { "source": { "sshConfig": {} }, "alias": "db" },
                "kind": "local",
                "bindAddress": "127.0.0.1",
                "bindPort": 15432
              }]
            }
            """.utf8)
            try malformed.write(to: paths.metadataFile)

            #expect(throws: SSHTunnelDefinitionError.missingTarget) {
                _ = try store.load()
            }
            #expect(throws: SSHTunnelDefinitionError.missingTarget) {
                try store.save(SSHHostMetadataFile(), expectedHash: SSHSecureFileWriter.hash(of: malformed))
            }
            #expect(try Data(contentsOf: paths.metadataFile) == malformed)
        }
    }

    @Test func preservesTunnelsWhenSavingUnrelatedMetadataChanges() throws {
        try withTemporaryMetadataStore { _, _, store in
            let initial = try store.load()
            let tunnel = localTunnel()
            let saved = try store.save(try SSHHostMetadataFile(tunnels: [tunnel]), expectedHash: initial.hash)
            var changed = saved.metadata
            changed.favorites = [SSHHostReference(source: .sshConfig, alias: "db")]

            _ = try store.save(changed, expectedHash: saved.hash)

            #expect(try store.load().metadata.tunnels == [tunnel])
        }
    }

    @Test func rejectsExternalBindWithoutConsentBeforeWriting() throws {
        try withTemporaryMetadataStore { _, paths, store in
            let initial = try store.load()
            var tunnel = localTunnel()
            tunnel.bindAddress = "0.0.0.0"

            #expect(throws: SSHTunnelDefinitionError.externalBindConsentRequired) {
                try store.save(SSHHostMetadataFile(tunnels: [tunnel]), expectedHash: initial.hash)
            }
            #expect(!FileManager.default.fileExists(atPath: paths.metadataFile.path))
        }
    }
}

private func localTunnel(id: UUID = UUID()) -> SSHTunnelDefinition {
    SSHTunnelDefinition(
        id: id,
        name: "Database",
        host: SSHHostReference(source: .sshConfig, alias: "db"),
        kind: .local,
        bindPort: 15432,
        targetHost: "db.internal",
        targetPort: 5432
    )
}

private func withTemporaryMetadataStore(
    _ body: (URL, SSHPaths, SSHHostMetadataStore) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = SSHPaths(
        home: root,
        systemConfig: root.appendingPathComponent("system-config"),
        runtimeRoot: root.appendingPathComponent("runtime"),
        environment: [:]
    )
    try body(root, paths, SSHHostMetadataStore(paths: paths))
}

private func permissions(of url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber).map(\.intValue)
}
