import Foundation
import Testing
@testable import Ghostty

/// The one-time copy of preferences and session files from `com.chostty.app`.
/// Every test uses a private defaults suite and temporary directories, so the
/// real preferences and `~/Library/Application Support` are never touched.
@Suite struct LegacyBundleMigrationTests {
    private struct Fixture {
        let defaults: UserDefaults
        let suiteName: String
        let legacyDirectory: URL
        let directory: URL

        init() throws {
            suiteName = "chostty.legacy-migration.tests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("chostty-legacy-migration-\(UUID().uuidString)", isDirectory: true)
            legacyDirectory = root.appendingPathComponent("com.chostty.app", isDirectory: true)
            directory = root.appendingPathComponent("kr.co.devch.chostty", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        }

        func migrate(_ legacyDefaults: [String: Any]?) {
            LegacyBundleMigration.migrate(
                from: "com.chostty.app",
                defaults: defaults,
                legacyDefaults: legacyDefaults,
                legacyDirectory: legacyDirectory,
                directory: directory
            )
        }

        func writeLegacy(_ name: String, _ contents: String) throws {
            try Data(contents.utf8).write(to: legacyDirectory.appendingPathComponent(name))
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: legacyDirectory.deletingLastPathComponent())
        }
    }

    @Test func legacyIdentifiersMapReleaseAndDebugSeparately() {
        #expect(LegacyBundleMigration.legacyIdentifier(for: "kr.co.devch.chostty") == "com.chostty.app")
        #expect(LegacyBundleMigration.legacyIdentifier(for: "kr.co.devch.chostty.debug") == "com.chostty.app.debug")
        #expect(LegacyBundleMigration.legacyIdentifier(for: "kr.co.devch.chostty.Tests") == nil)
    }

    @Test func copiesPreferencesWithoutOverwritingCurrentValues() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.defaults.set("current", forKey: "Shared")

        fixture.migrate(["Shared": "legacy", "OnlyLegacy": 42])

        #expect(fixture.defaults.string(forKey: "Shared") == "current")
        #expect(fixture.defaults.integer(forKey: "OnlyLegacy") == 42)
        #expect(fixture.defaults.bool(forKey: LegacyBundleMigration.completedKey))
    }

    @Test func copiesSessionFilesIntoANewDirectoryAndKeepsTheOriginals() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writeLegacy(SessionSnapshotRepository.primaryFileName, "primary")
        try fixture.writeLegacy(SessionSnapshotRepository.backupFileName, "backup")

        fixture.migrate(nil)

        #expect(try fixture.read(SessionSnapshotRepository.primaryFileName) == "primary")
        #expect(try fixture.read(SessionSnapshotRepository.backupFileName) == "backup")
        let legacyPrimary = fixture.legacyDirectory.appendingPathComponent(SessionSnapshotRepository.primaryFileName)
        #expect(FileManager.default.fileExists(atPath: legacyPrimary.path))
    }

    @Test func keepsASessionAlreadySavedUnderTheNewIdentifier() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writeLegacy(SessionSnapshotRepository.primaryFileName, "legacy")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("current".utf8).write(
            to: fixture.directory.appendingPathComponent(SessionSnapshotRepository.primaryFileName)
        )

        fixture.migrate(nil)

        #expect(try fixture.read(SessionSnapshotRepository.primaryFileName) == "current")
    }

    @Test func runsOnlyOnce() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.migrate(["First": 1])
        try fixture.writeLegacy(SessionSnapshotRepository.primaryFileName, "late")

        fixture.migrate(["Second": 2])

        #expect(fixture.defaults.object(forKey: "Second") == nil)
        let late = fixture.directory.appendingPathComponent(SessionSnapshotRepository.primaryFileName)
        #expect(!FileManager.default.fileExists(atPath: late.path))
    }
}
