import Foundation

/// Decides whether this process may write a session snapshot and whether it may
/// apply one at launch.
///
/// Both answers are the same value: every signal means "this is not an ordinary
/// user session", and then neither writing nor restoring is wanted.
///
/// - `GHOSTTY_MAC_DISABLE_SESSION_RESTORE=1` turns the feature off.
/// - `XCTestConfigurationFilePath` catches the unit-test host.
/// - `GHOSTTY_USER_DEFAULTS_SUITE` catches a UI test's app process, which does
///   NOT inherit the runner's environment. Without it the gate would stand open
///   in exactly the process that drives the real app against the developer's
///   own session file.
/// - Any launch argument other than Finder's `-psn_*` means an explicit open
///   intent, and restoring last time's layout over it would be wrong.
struct SessionPersistenceGate: Sendable {
    static let killSwitchVariable = "GHOSTTY_MAC_DISABLE_SESSION_RESTORE"

    /// Records that a boot began applying a snapshot. Only touched while the
    /// gate is open, so a gated process never creates the key.
    static let crashLoopMarkerKey = "chostty.sessionRestoreInProgress"

    private let environment: [String: String]
    private let arguments: [String]
    private let configEnabled: Bool

    /// `arguments` excludes the executable path.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        configEnabled: Bool = true
    ) {
        self.environment = environment
        self.arguments = arguments
        self.configEnabled = configEnabled
    }

    var shouldPersist: Bool { isEnabled }
    var shouldApplyOnBoot: Bool { isEnabled }

    private var isEnabled: Bool {
        guard configEnabled else { return false }
        guard environment[Self.killSwitchVariable] != "1" else { return false }
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        guard environment["GHOSTTY_USER_DEFAULTS_SUITE"] == nil else { return false }
        guard !hasExplicitOpenIntent else { return false }
        return true
    }

    private var hasExplicitOpenIntent: Bool {
        arguments.contains { !$0.hasPrefix("-psn_") }
    }

    // MARK: - Crash-loop marker

    /// Whether the previous launch died while applying a snapshot.
    func crashLoopMarkerIsSet(defaults: UserDefaults = .ghostty) -> Bool {
        guard isEnabled else { return false }
        return defaults.bool(forKey: Self.crashLoopMarkerKey)
    }

    /// A no-op when the gate is closed, which keeps a test host from writing
    /// the key into the shared defaults.
    func setCrashLoopMarker(_ value: Bool, defaults: UserDefaults = .ghostty) {
        guard isEnabled else { return }
        if value {
            defaults.set(true, forKey: Self.crashLoopMarkerKey)
        } else {
            defaults.removeObject(forKey: Self.crashLoopMarkerKey)
        }
    }
}
