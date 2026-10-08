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
        fileManager: FileManager = .default,
        copyItem: ((URL, URL) throws -> Void)? = nil
    ) {
        guard !defaults.bool(forKey: completedKey) else { return }

        let destinationFiles = sessionFileNames.map {
            directory.appendingPathComponent($0, isDirectory: false)
        }
        let hasCurrentSession = destinationFiles.contains {
            fileManager.fileExists(atPath: $0.path)
        }
        let sourceFileNames = sessionFileNames.filter {
            fileManager.fileExists(
                atPath: legacyDirectory.appendingPathComponent($0, isDirectory: false).path
            )
        }

        if !hasCurrentSession, !sourceFileNames.isEmpty {
            let scratch = directory.deletingLastPathComponent()
                .appendingPathComponent(".legacy-bundle-migration-\(UUID().uuidString)", isDirectory: true)
            let stagedDirectory = scratch.appendingPathComponent("sessions", isDirectory: true)
            let copy = copyItem ?? { source, destination in
                try fileManager.copyItem(at: source, to: destination)
            }
            defer {
                try? fileManager.removeItem(at: scratch)
            }

            do {
                try fileManager.createDirectory(
                    at: stagedDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                for name in sourceFileNames {
                    try copy(
                        legacyDirectory.appendingPathComponent(name, isDirectory: false),
                        stagedDirectory.appendingPathComponent(name, isDirectory: false)
                    )
                }

                // A session saved while the legacy files were prepared wins as
                // well; never merge a legacy primary with its current backup.
                guard !destinationFiles.contains(where: {
                    fileManager.fileExists(atPath: $0.path)
                }) else {
                    finish(
                        defaults: defaults,
                        legacyDefaults: legacyDefaults,
                        copiedFiles: 0,
                        legacy: legacy
                    )
                    return
                }

                if !fileManager.fileExists(atPath: directory.path) {
                    // Publishing the prepared directory is one rename, so a
                    // failed import cannot leave one legacy session slot behind.
                    try fileManager.moveItem(at: stagedDirectory, to: directory)
                } else {
                    // Preserve unrelated files already in this directory while
                    // publishing the session pair with one replacement.
                    let preparedDirectory = scratch.appendingPathComponent(
                        "destination",
                        isDirectory: true
                    )
                    try fileManager.copyItem(at: directory, to: preparedDirectory)
                    for name in sourceFileNames {
                        try fileManager.moveItem(
                            at: stagedDirectory.appendingPathComponent(name, isDirectory: false),
                            to: preparedDirectory.appendingPathComponent(name, isDirectory: false)
                        )
                    }
                    try fileManager.replaceItemAt(
                        directory,
                        withItemAt: preparedDirectory,
                        backupItemName: nil,
                        options: []
                    )
                }
            } catch {
                logger.error("failed to import sessions from \(legacy, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }

            finish(
                defaults: defaults,
                legacyDefaults: legacyDefaults,
                copiedFiles: sourceFileNames.count,
                legacy: legacy
            )
            return
        }

        finish(
            defaults: defaults,
            legacyDefaults: legacyDefaults,
            copiedFiles: 0,
            legacy: legacy
        )
    }

    private static func finish(
        defaults: UserDefaults,
        legacyDefaults: [String: Any]?,
        copiedFiles: Int,
        legacy: String
    ) {
        var copiedKeys = 0
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copiedKeys += 1
        }

        defaults.set(true, forKey: completedKey)
        if copiedKeys > 0 || copiedFiles > 0 {
            logger.info("migrated \(copiedKeys) preferences and \(copiedFiles) session files from \(legacy, privacy: .public)")
        }
    }
}
