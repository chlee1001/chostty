import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHHostCatalogTests {
    @Test func unchangedObservationsDoNotReadConfigurationAgain() throws {
        try withCatalogFixture { _, paths in
            try "Host one\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let fileSystem = CountingSSHFileSystem()
            let catalog = SSHHostCatalog(paths: paths, fileSystem: fileSystem)
            #expect(catalog.revalidate(SSHHostReference(source: .sshConfig, alias: "one")))
            fileSystem.resetReadCount()

            catalog.refreshIfStale()

            #expect(fileSystem.readCount == 0)
            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["one"])
        }
    }

    @Test func favoritesComeFirstAndEachGroupKeepsConfigOrder() throws {
        try withCatalogFixture { _, paths in
            try "Host alpha\nHost beta\nHost gamma\nHost delta\n"
                .write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths)
            #expect(catalog.revalidate(SSHHostReference(source: .sshConfig, alias: "alpha")))

            catalog.setPresentationMetadata(
                displayNames: [:],
                favorites: [
                    SSHHostReference(source: .sshConfig, alias: "gamma"),
                    SSHHostReference(source: .sshConfig, alias: "beta"),
                ])

            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["beta", "gamma", "alpha", "delta"])
            #expect(catalog.snapshot.entries.map(\.isFavorite) == [true, true, false, false])

            catalog.setPresentationMetadata(displayNames: [:], favorites: [])

            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["alpha", "beta", "gamma", "delta"])
        }
    }

    @Test func includeTargetChangeRefreshesCatalog() throws {
        try withCatalogFixture { root, paths in
            let include = root.appendingPathComponent(".ssh/included")
            try "Host one\n".write(to: include, atomically: true, encoding: .utf8)
            try "Include included\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths)
            #expect(catalog.revalidate(SSHHostReference(source: .sshConfig, alias: "one")))

            try "Host replacement-longer\n".write(to: include, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()

            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["replacement-longer"])
        }
    }

    @Test func rootThatAppearsLaterRefreshesCatalog() throws {
        try withCatalogFixture { _, paths in
            let catalog = SSHHostCatalog(paths: paths)
            #expect(!catalog.revalidate(SSHHostReference(source: .sshConfig, alias: "later")))

            try "Host later\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()

            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["later"])
        }
    }

    @Test func globDirectoryMembershipChangesRefreshCatalog() throws {
        try withCatalogFixture { root, paths in
            let snippets = root.appendingPathComponent(".ssh/snippets", isDirectory: true)
            try FileManager.default.createDirectory(at: snippets, withIntermediateDirectories: true)
            try "Include snippets/*.conf\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths)
            _ = catalog.revalidate(SSHHostReference(source: .sshConfig, alias: "missing"))

            let include = snippets.appendingPathComponent("one.conf")
            try "Host one\n".write(to: include, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()
            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["one"])

            try FileManager.default.removeItem(at: include)
            catalog.refreshIfStale()
            #expect(catalog.snapshot.entries.isEmpty)
        }
    }

    @Test func firstDuplicateAliasWinsAcrossUserAndSystemConfiguration() throws {
        try withCatalogFixture { root, paths in
            try "Host shared\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("etc"), withIntermediateDirectories: true)
            try "Host shared system\n".write(to: paths.systemConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths)
            _ = catalog.revalidate(SSHHostReference(source: .sshConfig, alias: "shared"))

            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["shared", "system"])
            #expect(catalog.snapshot.entries.first?.definedIn == paths.userConfig)
            #expect(catalog.snapshot.diagnostics.contains(.duplicateAlias("shared", paths.systemConfig, 1)))
        }
    }

    @Test func managedReferencesAreRejectedUntilManagedHostsExist() throws {
        try withCatalogFixture { _, paths in
            let catalog = SSHHostCatalog(paths: paths)
            let reference = SSHHostReference(source: .managed(hostID: UUID()), alias: "managed")

            #expect(catalog.revalidation(for: reference) == .blocked(.hostRemoved))
            #expect(!catalog.revalidate(reference))
        }
    }

    @Test func managedHostsAreCatalogEntriesAndWinAliasCollisions() throws {
        try withCatalogFixture { _, paths in
            let hostID = UUID()
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try managedConfig(hostID: hostID, alias: "shared").write(
                to: paths.managedHostsFile,
                atomically: true,
                encoding: .utf8)
            try "Host shared user-only\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: paths.systemConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try "Host shared system-only\n".write(to: paths.systemConfig, atomically: true, encoding: .utf8)

            let catalog = SSHHostCatalog(paths: paths)
            let reference = SSHHostReference(source: .managed(hostID: hostID), alias: "shared")

            #expect(catalog.revalidation(for: reference) == .valid)
            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["shared", "user-only", "system-only"])
            #expect(catalog.snapshot.entries.first?.reference == reference)
            #expect(catalog.snapshot.diagnostics.contains(.duplicateAlias("shared", paths.userConfig, 1)))
            #expect(catalog.snapshot.diagnostics.contains(.duplicateAlias("shared", paths.systemConfig, 1)))
        }
    }

    @Test func managedScanTracksNestedIncludesWithoutCatalogingInheritedHosts() throws {
        try withCatalogFixture { _, paths in
            let hostID = UUID()
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            let nested = paths.dataDirectory.appendingPathComponent("nested.conf")
            let child = paths.dataDirectory.appendingPathComponent("child.conf")
            try "Include \(child.path)\n".write(to: nested, atomically: true, encoding: .utf8)
            try "Host inherited\n".write(to: child, atomically: true, encoding: .utf8)
            try (managedConfig(hostID: hostID, alias: "managed") + "\nHost outside\nInclude \(nested.path)\n").write(
                to: paths.managedHostsFile,
                atomically: true,
                encoding: .utf8)

            let catalog = SSHHostCatalog(paths: paths)
            _ = catalog.revalidation(for: SSHHostReference(source: .managed(hostID: hostID), alias: "managed"))
            #expect(catalog.snapshot.entries.map(\.reference.alias) == ["managed"])
            #expect(catalog.snapshot.observations[child.path] != nil)

            try "Match exec true\n".write(to: child, atomically: true, encoding: .utf8)
            catalog.refreshIfStale()

            #expect(catalog.snapshot.containsMatchExec)
            #expect(catalog.snapshot.observations[nested.path] != nil)
            #expect(catalog.snapshot.observations[child.path] != nil)
        }
    }

    @Test func unreadableManagedConfigurationFailsClosedWithoutOrdinaryAliasFallback() throws {
        try withCatalogFixture { _, paths in
            let hostID = UUID()
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try managedConfig(hostID: hostID, alias: "prod").write(
                to: paths.managedHostsFile,
                atomically: true,
                encoding: .utf8)
            try "Host prod\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths, fileSystem: ManagedReadFailingFileSystem(paths.managedHostsFile))
            let reference = SSHHostReference(source: .managed(hostID: hostID), alias: "prod")

            #expect(catalog.revalidation(for: reference) == .blocked(.configUnreadable))
            #expect(!catalog.snapshot.entries.contains(where: { $0.reference.source == .managed(hostID: hostID) }))
            #expect(catalog.snapshot.entries.contains(where: { $0.reference == .init(source: .sshConfig, alias: "prod") }))
        }
    }

    @Test func uniqueAliasValidationIncludesUnmarkedManagedBlocksAndOnlyExcludesOwnID() throws {
        try withCatalogFixture { _, paths in
            let hostID = UUID()
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try (managedConfig(hostID: hostID, alias: "owned") + "\nHost outside\n").write(
                to: paths.managedHostsFile,
                atomically: true,
                encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths)

            try catalog.validateUniqueAlias("owned", excluding: hostID)
            #expect(throws: SSHStoreError.duplicateAlias("owned")) {
                try catalog.validateUniqueAlias("owned", excluding: nil)
            }
            #expect(throws: SSHStoreError.duplicateAlias("outside")) {
                try catalog.validateUniqueAlias("outside", excluding: nil)
            }

            try "Host owned\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: paths.systemConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try "Host owned\n".write(to: paths.systemConfig, atomically: true, encoding: .utf8)
            #expect(throws: SSHStoreError.duplicateAlias("owned")) {
                try catalog.validateUniqueAlias("owned", excluding: hostID)
            }
        }
    }

    @Test func uniqueAliasValidationRejectsUnreadableExternalIncludeGraph() throws {
        try withCatalogFixture { root, paths in
            let include = root.appendingPathComponent(".ssh/unreadable.conf")
            try "Host external\n".write(to: include, atomically: true, encoding: .utf8)
            try "Include unreadable.conf\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths, fileSystem: ManagedReadFailingFileSystem(include))

            #expect(throws: SSHStoreError.readFailed(EACCES)) {
                try catalog.validateUniqueAlias("new-host", excluding: nil)
            }
        }
    }

    @Test func presentationMetadataAndResolvedDestinationSurviveFreshScans() throws {
        try withCatalogFixture { _, paths in
            let hostID = UUID()
            let managedReference = SSHHostReference(source: .managed(hostID: hostID), alias: "managed")
            let userReference = SSHHostReference(source: .sshConfig, alias: "user")
            let destination = SSHResolvedDestination(user: "me", hostName: "example.test", port: 2222)
            try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
            try managedConfig(hostID: hostID, alias: "managed").write(
                to: paths.managedHostsFile,
                atomically: true,
                encoding: .utf8)
            try "Host user\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let catalog = SSHHostCatalog(paths: paths)

            _ = catalog.revalidation(for: managedReference)
            catalog.setPresentationMetadata(
                displayNames: [hostID: "Managed host"],
                favorites: [userReference])
            catalog.updateResolvedDestination(destination, for: managedReference)
            _ = catalog.revalidation(for: managedReference)

            #expect(catalog.snapshot.entries.map(\.reference) == [userReference, managedReference])
            let managed = try #require(catalog.snapshot.entries.first(where: { $0.reference == managedReference }))
            #expect(managed.displayName == "Managed host")
            #expect(managed.resolved == destination)
            #expect(catalog.snapshot.entries.first?.isFavorite == true)
        }
    }
}

private final class CountingSSHFileSystem: SSHFileSystem, @unchecked Sendable {
    private let local = LocalSSHFileSystem()
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.withLock { reads }
    }

    func resetReadCount() {
        lock.withLock { reads = 0 }
    }

    func contents(of url: URL) throws -> String {
        lock.withLock { reads += 1 }
        return try local.contents(of: url)
    }

    func metadata(of url: URL) throws -> SSHFileStat {
        try local.metadata(of: url)
    }

    func glob(_ pattern: String) throws -> [URL] {
        try local.glob(pattern)
    }

    func realpath(_ url: URL) -> URL? {
        local.realpath(url)
    }
}

private final class ManagedReadFailingFileSystem: SSHFileSystem, @unchecked Sendable {
    private let managedFile: URL
    private let local = LocalSSHFileSystem()

    init(_ managedFile: URL) {
        self.managedFile = managedFile
    }

    func contents(of url: URL) throws -> String {
        guard url == managedFile else { return try local.contents(of: url) }
        throw POSIXError(.EACCES)
    }

    func metadata(of url: URL) throws -> SSHFileStat {
        try local.metadata(of: url)
    }

    func glob(_ pattern: String) throws -> [URL] {
        try local.glob(pattern)
    }

    func realpath(_ url: URL) -> URL? {
        local.realpath(url)
    }
}

private func managedConfig(hostID: UUID, alias: String) -> String {
    """
    # chostty-host-id: \(hostID.uuidString)
    Host \(alias)
        HostName example.test
    """
}

private func withCatalogFixture(_ body: (URL, SSHPaths) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ssh = root.appendingPathComponent(".ssh", isDirectory: true)
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    let paths = SSHPaths(
        home: root,
        userConfig: ssh.appendingPathComponent("config"),
        systemConfig: root.appendingPathComponent("etc/ssh_config"),
        runtimeRoot: root.appendingPathComponent("runtime")
    )
    try body(root, paths)
}
