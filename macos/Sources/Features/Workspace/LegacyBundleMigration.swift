import Foundation
import OSLog

/// Carries user state across the bundle identifier change from
/// `com.chostty.app` to `kr.co.devch.chostty`.
///
/// macOS keys preferences and Application Support by bundle identifier, so the
/// renamed app would otherwise start with empty settings and no saved session.
/// The migration runs once per identifier before `NSApplicationMain`, so it
/// lands before any `@AppStorage`, Sparkle or session restore reads.
///
/// Values are copied, never moved: the old build may still be running or be
/// reinstalled, and a copy keeps a downgrade working. Anything already present
/// under the new identifier wins.
enum LegacyBundleMigration {
    /// Preference key recording that this identifier has already migrated.
    static let completedKey = "ChosttyLegacyBundleMigrationCompleted"

    /// Session files the persistence layer reads from Application Support.
    static let sessionFileNames = [
        SessionSnapshotRepository.primaryFileName,
        SessionSnapshotRepository.backupFileName,
    ]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "kr.co.devch.chostty",
        category: "legacy-bundle-migration"
    )

    /// The identifier a given bundle identifier was renamed from, if any.
    static func legacyIdentifier(for bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "kr.co.devch.chostty": "com.chostty.app"
        case "kr.co.devch.chostty.debug": "com.chostty.app.debug"
        default: nil
        }
    }

    /// Run the migration for the running app.
    static func run() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let legacy = legacyIdentifier(for: bundleIdentifier)
        else { return }

        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        migrate(
            from: legacy,
            defaults: .standard,
            legacyDefaults: UserDefaults.standard.persistentDomain(forName: legacy),
            legacyDirectory: applicationSupport.appendingPathComponent(legacy, isDirectory: true),
            directory: applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        )
    }

    /// Copy preferences and session files from the legacy identifier.
    ///
    /// - Parameters:
    ///   - legacyDefaults: The legacy domain read with
    ///     `persistentDomain(forName:)`, which excludes the global domain.
    ///   - legacyDirectory: Application Support directory of the old identifier.
    ///   - directory: Application Support directory of the current identifier.
    static func migrate(
        from legacy: String,
        defaults: UserDefaults,
        legacyDefaults: [String: Any]?,
        legacyDirectory: URL,
        directory: URL,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: completedKey) else { return }

        var copiedKeys = 0
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copiedKeys += 1
        }

        var copiedFiles = 0
        for name in sessionFileNames {
            let source = legacyDirectory.appendingPathComponent(name, isDirectory: false)
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path)
            else { continue }

            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.copyItem(at: source, to: destination)
                copiedFiles += 1
            } catch {
                logger.error("failed to copy \(name, privacy: .public) from \(legacy, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        defaults.set(true, forKey: completedKey)
        if copiedKeys > 0 || copiedFiles > 0 {
            logger.info("migrated \(copiedKeys) preferences and \(copiedFiles) session files from \(legacy, privacy: .public)")
        }
    }
}
