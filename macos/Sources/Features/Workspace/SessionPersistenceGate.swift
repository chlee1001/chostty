import Foundation

/// Decides whether this process may write a session snapshot and whether it may
/// apply one at launch.
///
/// The configuration key and the signals below mean "this is not an ordinary
/// user session"; then neither writing nor restoring is wanted:
///
/// - `GHOSTTY_MAC_DISABLE_SESSION_RESTORE=1` turns the feature off.
/// - `XCTestConfigurationFilePath` catches the unit-test host.
/// - `GHOSTTY_USER_DEFAULTS_SUITE` catches a UI test's app process, which does
///   NOT inherit the runner's environment. Without it the gate would stand open
///   in exactly the process that drives the real app against the developer's
///   own session file.
///
/// An explicit open intent — any launch argument other than Finder's `-psn_*`
/// — only stops the stored layout from being applied over what the user asked
/// for. The launch still saves; the stored windows it does not open are kept.
struct SessionPersistenceGate: Sendable {
    static let killSwitchVariable = "GHOSTTY_MAC_DISABLE_SESSION_RESTORE"

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
    var shouldApplyOnBoot: Bool { isEnabled && !hasExplicitOpenIntent }

    private var isEnabled: Bool {
        guard configEnabled else { return false }
        guard environment[Self.killSwitchVariable] != "1" else { return false }
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        guard environment["GHOSTTY_USER_DEFAULTS_SUITE"] == nil else { return false }
        return true
    }

    private var hasExplicitOpenIntent: Bool {
        arguments.contains { !$0.hasPrefix("-psn_") }
    }

}
