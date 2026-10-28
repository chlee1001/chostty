import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHManagedHostStoreTests {
    @Test func derivesManagedPathsFromInjectedHomeAndEnvironment() throws {
        try withTemporaryManagedStore { root, _, _ in
            let configured = root.appendingPathComponent("xdg")
            let paths = SSHPaths(
                home: root,
                runtimeRoot: root.appendingPathComponent("runtime"),
                environment: ["XDG_CONFIG_HOME": configured.path]
            )

            #expect(paths.dataDirectory == configured.appendingPathComponent("chostty/ssh", isDirectory: true))
            #expect(paths.managedHostsFile == paths.dataDirectory.appendingPathComponent("hosts.conf"))
            #expect(paths.metadataFile == paths.dataDirectory.appendingPathComponent("hosts.meta.json"))

            #if DEBUG
            let override = root.appendingPathComponent("override", isDirectory: true)
            let overridden = SSHPaths(
                home: root,
                runtimeRoot: root.appendingPathComponent("runtime"),
                environment: ["CHOSTTY_SSH_DATA_DIR": override.path]
            )
            #expect(overridden.dataDirectory == override)
            #endif
        }
    }

    @Test func documentRoundTripsUntouchedBytesAndFindsMatchingBlocks() {
        let source = Data("Host first second\r\n    User deploy\r\nHost *\r\n    ForwardAgent yes\r\nMatch user root\r\n".utf8)
        let document = SSHConfigDocument(data: source)

        #expect(document.data == source)
        #expect(document.blocks(matching: "second").map(\.line) == [1, 3, 5])
    }

    @Test func createsPrivateFileAndDirectories() throws {
        try withTemporaryManagedStore { _, paths, store in
            let loaded = try store.load()
            let host = try managedHost(alias: "db")
            _ = try store.save(host, expectedHash: loaded.hash)

            #expect(permissions(of: paths.managedHostsFile) == 0o600)
            #expect(permissions(of: paths.dataDirectory) == 0o700)
            #expect(permissions(of: paths.dataDirectory.deletingLastPathComponent()) == 0o700)
        }
    }

    @Test func mapsMissingAndUnreadableFilesDistinctly() throws {
        try withTemporaryManagedStore { _, paths, _ in
            let writer = SSHSecureFileWriter()
            let missing = try writer.read(at: paths.managedHostsFile)
            #expect(missing.data == nil)
            #expect(missing.hash == nil)

            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try "private".write(to: paths.managedHostsFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.managedHostsFile.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.managedHostsFile.path)
            }

            #expect(throws: SSHStoreError.readFailed(EACCES)) {
                try writer.read(at: paths.managedHostsFile)
            }
        }
    }

    @Test func preservesExistingParentPermissions() throws {
        try withTemporaryManagedStore { _, paths, store in
            let parent = paths.dataDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)

            _ = try store.save(managedHost(alias: "db"), expectedHash: nil)

            #expect(permissions(of: parent) == 0o755)
        }
    }

    @Test func refusesAHashConflict() throws {
        try withTemporaryManagedStore { _, paths, store in
            let initial = try store.load()
            _ = try store.save(managedHost(alias: "db"), expectedHash: initial.hash)
            let stale = initial.hash
            try "external\n".write(to: paths.managedHostsFile, atomically: true, encoding: .utf8)

            #expect(throws: SSHStoreError.changedOnDisk) {
                try store.save(managedHost(alias: "cache"), expectedHash: stale)
            }
        }
    }

    @Test func injectedWriteFailureLeavesOriginalAndNoTemporaryFile() throws {
        try withTemporaryManagedStore { _, paths, store in
            let loaded = try store.load()
            _ = try store.save(managedHost(alias: "db"), expectedHash: loaded.hash)
            let before = try Data(contentsOf: paths.managedHostsFile)
            let snapshot = try store.load()
            let failingStore = SSHManagedHostStore(
                paths: paths,
                writer: SSHSecureFileWriter(failurePoint: .beforeWrite)
            )

            #expect(throws: SSHStoreError.writeFailed(EIO)) {
                try failingStore.save(managedHost(alias: "cache"), expectedHash: snapshot.hash)
            }
            #expect(try Data(contentsOf: paths.managedHostsFile) == before)
            let names = try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path)
            #expect(!names.contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test func writesThroughASymbolicLink() throws {
        try withTemporaryManagedStore { root, paths, store in
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            let target = root.appendingPathComponent("dotfiles/hosts.conf")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# existing\n".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: paths.managedHostsFile, withDestinationURL: target)
            let loaded = try store.load()

            _ = try store.save(managedHost(alias: "db"), expectedHash: loaded.hash)

            #expect((try? paths.managedHostsFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
            #expect(try String(contentsOf: target, encoding: .utf8).contains("Host db"))
        }
    }

    @Test func preservesUnknownLinesAndAppendsRequiredTail() throws {
        try withTemporaryManagedStore { _, paths, store in
            let id = UUID()
            let source = """
            # preserved preamble
            # chostty-host-id: \(id.uuidString)
            Host db
                HostName db.example
                Compression yes
                # preserved comment
            Host outside
                HostName outside.example
            """
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try source.write(to: paths.managedHostsFile, atomically: true, encoding: .utf8)
            let loaded = try store.load()
            var host = try #require(loaded.hosts.first)
            host.user = "deploy"

            _ = try store.save(host, expectedHash: loaded.hash)
            let written = try String(contentsOf: paths.managedHostsFile, encoding: .utf8)

            #expect(written.contains("    Compression yes"))
            #expect(written.contains("    # preserved comment"))
            #expect(written.contains("Host outside\n    HostName outside.example"))
            #expect(written.hasSuffix("Host *\n    Include ~/.ssh/config\n    Include /etc/ssh/ssh_config\n"))
        }
    }

    @Test func rejectsScalarInjection() {
        #expect(throws: SSHStoreError.invalidScalarValue("db\nHost injected")) {
            try SSHManagedHost(hostID: UUID(), alias: "db", hostName: "db\nHost injected")
        }
    }

    @Test func rejectsMutatedHostBeforeReplacingOriginalFile() throws {
        try withTemporaryManagedStore { _, paths, store in
            var host = try managedHost(alias: "db")
            let saved = try store.save(host, expectedHash: nil)
            let original = try Data(contentsOf: paths.managedHostsFile)
            host.hostName = "db\nHost injected"
            #expect(throws: SSHStoreError.invalidScalarValue(host.hostName)) {
                try store.save(host, expectedHash: saved.hash)
            }
            #expect(try Data(contentsOf: paths.managedHostsFile) == original)
        }
    }

    @Test func createsMissingSymlinkTargetWithoutReplacingLink() throws {
        try withTemporaryManagedStore { root, _, _ in
            let target = root.appendingPathComponent("target.conf")
            let link = root.appendingPathComponent("linked.conf")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.conf")
            let data = Data("Host test\n".utf8)
            try SSHSecureFileWriter().write(data, to: link, expectedHash: nil)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.conf")
            #expect(try Data(contentsOf: target) == data)
        }
    }

    @Test func refusesSymlinkCyclesWithoutReplacingEitherLink() throws {
        try withTemporaryManagedStore { root, _, _ in
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second")
            try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "first")
            #expect(throws: SSHStoreError.readFailed(ELOOP)) {
                try SSHSecureFileWriter().write(Data(), to: first, expectedHash: nil)
            }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: first.path) == "second")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: second.path) == "first")
        }
    }
}

private func withTemporaryManagedStore(
    _ body: (URL, SSHPaths, SSHManagedHostStore) throws -> Void
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
    try body(root, paths, SSHManagedHostStore(paths: paths))
}

private func managedHost(alias: String) throws -> SSHManagedHost {
    try SSHManagedHost(hostID: UUID(), alias: alias, hostName: "\(alias).example")
}

private func permissions(of url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber).map(\.intValue)
}
