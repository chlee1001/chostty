import Foundation
import OSLog

/// Reads and writes the session snapshot file.
///
/// Stateless and synchronous: `applicationWillTerminate` must finish its write
/// before returning, and a synchronous AppKit callback cannot await an actor.
/// Callers serialize themselves.
///
/// The directory is injectable so tests never touch real Application Support,
/// and the default derives from the bundle identifier. A Debug build is
/// `kr.co.devch.chostty.debug` and would otherwise overwrite the release app's
/// file.
struct SessionSnapshotRepository: Sendable {
    /// Directory holding `session.json` and `session-previous.json`.
    let directory: URL

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "kr.co.devch.chostty",
        category: "session-persistence"
    )

    static let primaryFileName = "session.json"
    static let backupFileName = "session-previous.json"

    init(directory: URL) {
        self.directory = directory
    }

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) {
        self.directory = Self.defaultDirectory(
            bundleIdentifier: bundleIdentifier,
            fileManager: fileManager
        )
    }

    /// `~/Library/Application Support/<bundle id>/`.
    static func defaultDirectory(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(bundleIdentifier ?? "kr.co.devch.chostty", isDirectory: true)
    }

    var primaryURL: URL { directory.appendingPathComponent(Self.primaryFileName, isDirectory: false) }
    var backupURL: URL { directory.appendingPathComponent(Self.backupFileName, isDirectory: false) }

    // MARK: - Saving

    enum SaveOutcome: Equatable {
        case written
        /// The encoded bytes matched the file on disk. This is what keeps an
        /// idle app from touching the disk on every tick.
        case skippedIdentical
        /// Not loadable; the previous valid file is left untouched.
        case refusedInvalid(SessionSnapshotValidator.Rejection)
    }

    @discardableResult
    func save(_ snapshot: AppSessionSnapshot) throws -> SaveOutcome {
        let validated: AppSessionSnapshot
        switch SessionSnapshotValidator.validate(snapshot) {
        case .success(let snapshot):
            validated = snapshot
        case .failure(let rejection):
            Self.logger.warning("session.persist.refusedInvalid \(rejection.description, privacy: .public)")
            return .refusedInvalid(rejection)
        }

        let encoded = try Self.encoder.encode(validated)
        if let rejection = Self.resourceRejection(for: encoded) {
            Self.logger.warning("session.persist.refusedInvalid \(rejection.description, privacy: .public)")
            return .refusedInvalid(rejection)
        }
        let existing = try? Data(contentsOf: primaryURL)
        if existing == encoded {
            return .skippedIdentical
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing, case .success = Self.validate(existing) {
            // Secure the previous valid bytes before replacing the primary.
            // A backup write failure must leave the primary intact for retry.
            try existing.write(to: backupURL, options: [.atomic])
            restrictPermissions(of: backupURL)
        }
        try encoded.write(to: primaryURL, options: [.atomic])
        // `.atomic` replaces the file, so permissions are reapplied after every
        // write rather than once at creation.
        restrictPermissions(of: primaryURL)
        return .written
    }

    /// Promotes the primary file to the backup slot.
    ///
    /// Seeds the backup right after a boot successfully applied the primary.
    /// Changed saves then roll it forward to the immediately preceding valid
    /// primary, so recovery is not limited to the starting state of that boot.
    /// A missing primary is not an error; invalid bytes are never promoted.
    func promotePrimaryToBackup() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: primaryURL.path) else { return }

        let data = try Data(contentsOf: primaryURL)
        _ = try Self.validate(data).get()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: backupURL, options: [.atomic])
        restrictPermissions(of: backupURL)
    }

    /// The file records working directories and titles, and `FORK.md` states it
    /// is `0600`. A silent failure would leave that promise untrue with nothing
    /// to notice it by.
    private func restrictPermissions(of url: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Self.logger.warning(
                "session.persist.permissionsNotRestricted path=\(url.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Loading

    enum Source: Equatable {
        case primary
        case backup
    }

    enum LoadOutcome: Equatable {
        case absent
        case loaded(AppSessionSnapshot, source: Source)
        /// Neither slot is usable; the reason is the primary's.
        case unusable(reason: String)
    }

    /// Prefers the primary, falling back to the previous validated snapshot.
    func load() -> LoadOutcome {
        var primaryFailure: String?

        switch read(primaryURL) {
        case .success(let snapshot):
            return .loaded(snapshot, source: .primary)
        case .failure(.missing):
            break
        case .failure(let failure):
            primaryFailure = failure.description
            Self.logger.warning("session.restore.primaryUnusable \(failure.description, privacy: .public)")
        }

        switch read(backupURL) {
        case .success(let snapshot):
            return .loaded(snapshot, source: .backup)
        case .failure(.missing):
            return primaryFailure.map { .unusable(reason: $0) } ?? .absent
        case .failure(let failure):
            Self.logger.warning("session.restore.backupUnusable \(failure.description, privacy: .public)")
            return .unusable(reason: primaryFailure ?? failure.description)
        }
    }

    struct StoredOwner: Decodable, Equatable {
        let ownerInstanceID: UUID
        let ownerPID: Int32
    }

    /// The writer recorded in the primary file, decoded without the workspace
    /// graph. Ownership is a property of the file on disk, so it stays readable
    /// even when the graph itself would fail restore validation.
    func storedOwner() -> StoredOwner? {
        guard let data = try? Data(contentsOf: primaryURL),
              Self.resourceRejection(for: data) == nil else { return nil }
        return try? JSONDecoder().decode(StoredOwner.self, from: data)
    }

    private enum ReadFailure: Error, CustomStringConvertible {
        case missing
        case decode(String)
        case rejected(SessionSnapshotValidator.Rejection)

        var description: String {
            switch self {
            case .missing: return "missing"
            case .decode(let message): return "reason=decodeError detail=\(message)"
            case .rejected(let rejection): return "reason=\(rejection.description)"
            }
        }
    }

    /// An encoded-byte bound shared by saving and loading. Character limits
    /// alone do not bound UTF-8 size, especially for combining characters.
    static let maxFileBytes = 4 * 1024 * 1024

    /// `JSONDecoder` recurses per level, so a file nested a few thousand deep
    /// exhausts the stack before any value-level depth check can run. Counting
    /// brackets over the raw bytes first makes that unreachable.
    static let maxNestingDepth = SessionSnapshotValidator.Limits.paneTreeDepth * 4

    /// Maximum bracket nesting in `data`, ignoring brackets inside strings.
    static func nestingDepth(of data: Data) -> Int {
        var depth = 0
        var maximum = 0
        var inString = false
        var escaped = false

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                maximum = max(maximum, depth)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }

        return maximum
    }

    private func read(_ url: URL) -> Result<AppSessionSnapshot, ReadFailure> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.missing) }
        return Self.validate(data)
    }

    /// Loading and backup rotation must accept exactly the same bytes.
    private static func validate(_ data: Data) -> Result<AppSessionSnapshot, ReadFailure> {
        if let rejection = Self.resourceRejection(for: data) {
            return .failure(.rejected(rejection))
        }

        let decoded: AppSessionSnapshot
        do {
            decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        } catch {
            return .failure(.decode(String(describing: error)))
        }

        switch SessionSnapshotValidator.validate(decoded) {
        case .success(let snapshot):
            return .success(snapshot)
        case .failure(let rejection):
            return .failure(.rejected(rejection))
        }
    }

    private static func resourceRejection(for data: Data) -> SessionSnapshotValidator.Rejection? {
        guard data.count <= maxFileBytes else {
            return .limitExceeded(kind: "fileBytes", count: data.count, limit: maxFileBytes)
        }
        let depth = nestingDepth(of: data)
        guard depth <= maxNestingDepth else {
            return .limitExceeded(kind: "jsonNestingDepth", count: depth, limit: maxNestingDepth)
        }
        return nil
    }

    // MARK: - Encoding

    /// Sorted keys keep the encoding deterministic, which the identical-bytes
    /// skip depends on.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
