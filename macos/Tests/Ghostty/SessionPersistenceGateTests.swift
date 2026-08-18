import Foundation
import Testing
@testable import Ghostty

/// The gate is injected with an environment dictionary and an argument array
/// rather than reading the process, so both directions are provable: a bare
/// environment opens it, each signal closes it. Asserting only "closed inside
/// this test process" would pass even for `return false`.
@Suite struct SessionPersistenceGateTests {
    private func gate(
        environment: [String: String] = [:],
        arguments: [String] = [],
        configEnabled: Bool = true
    ) -> SessionPersistenceGate {
        SessionPersistenceGate(
            environment: environment,
            arguments: arguments,
            configEnabled: configEnabled
        )
    }

    // MARK: - Signal table

    @Test func ordinaryLaunchIsAllowed() {
        let gate = gate()
        #expect(gate.shouldPersist)
        #expect(gate.shouldApplyOnBoot)
    }

    @Test func finderProcessSerialNumberArgumentIsStillAnOrdinaryLaunch() {
        // Finder appends `-psn_*` on a normal open; not an explicit intent.
        let gate = gate(arguments: ["-psn_0_12345"])
        #expect(gate.shouldPersist)
        #expect(gate.shouldApplyOnBoot)
    }

    @Test func xctestEnvironmentClosesTheGate() {
        let gate = gate(environment: ["XCTestConfigurationFilePath": "/x"])
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    /// The UI-test signal. The app under test does not inherit
    /// `XCTestConfigurationFilePath` from the runner, but
    /// `GhosttyCustomConfigCase` always injects this one.
    @Test func userDefaultsSuiteClosesTheGate() {
        let gate = gate(environment: ["GHOSTTY_USER_DEFAULTS_SUITE": "GHOSTTY_UI_TESTS"])
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    @Test func killSwitchClosesTheGate() {
        let gate = gate(environment: [SessionPersistenceGate.killSwitchVariable: "1"])
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    @Test func killSwitchOnlyTriggersOnExactlyOne() {
        // Guards against "any value means on", where an accidental empty
        // export would disable the feature.
        #expect(gate(environment: [SessionPersistenceGate.killSwitchVariable: "0"]).shouldPersist)
        #expect(gate(environment: [SessionPersistenceGate.killSwitchVariable: ""]).shouldPersist)
    }

    @Test func applePersistenceArgumentsCloseTheGate() {
        let gate = gate(arguments: ["-ApplePersistenceIgnoreState", "YES"])
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    @Test func arbitraryLaunchArgumentClosesTheGate() {
        // `ghostty -e ...`, `open --args`: the user asked for something
        // specific, so last session's layout must not land on top.
        #expect(!gate(arguments: ["-e", "top"]).shouldApplyOnBoot)
        #expect(!gate(arguments: ["--config-file=/tmp/x"]).shouldApplyOnBoot)
    }

    @Test func configuredOffClosesTheGate() {
        let gate = gate(configEnabled: false)
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    @Test func killSwitchNameStaysInTheGhosttyEnvironmentNamespace() {
        // `GHOSTTY_*` is the frozen runtime prefix; `CHOSTTY_*` would open a
        // namespace with no precedent.
        #expect(SessionPersistenceGate.killSwitchVariable.hasPrefix("GHOSTTY_"))
    }

    // MARK: - Crash-loop marker

    @Test func markerRoundTripsWhenTheGateIsOpen() throws {
        let defaults = try #require(UserDefaults(suiteName: "chostty.gate.tests.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let gate = gate()

        #expect(!gate.crashLoopMarkerIsSet(defaults: defaults))
        gate.setCrashLoopMarker(true, defaults: defaults)
        #expect(gate.crashLoopMarkerIsSet(defaults: defaults))
        gate.setCrashLoopMarker(false, defaults: defaults)
        #expect(!gate.crashLoopMarkerIsSet(defaults: defaults))
    }

    /// A gated process must not create the key, or every test run leaves
    /// persistence bookkeeping in the shared defaults.
    @Test func closedGateNeverCreatesTheMarkerKey() throws {
        let suiteName = "chostty.gate.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let closed = gate(environment: ["XCTestConfigurationFilePath": "/x"])
        closed.setCrashLoopMarker(true, defaults: defaults)

        #expect(defaults.object(forKey: SessionPersistenceGate.crashLoopMarkerKey) == nil)
        #expect(!closed.crashLoopMarkerIsSet(defaults: defaults))
    }

    /// This process is an XCTest host, so the process-backed default must be
    /// closed. The injected cases above prove it is not simply `false`.
    @Test func processDefaultsAreClosedInsideTheTestHost() {
        #expect(!SessionPersistenceGate().shouldPersist)
    }

    // MARK: - Configuration key

    @Test func configuredOffInAConfigFileClosesTheGate() throws {
        let config = try TemporaryConfig("macos-session-persistence = false")
        #expect(!config.macosSessionPersistence)

        let gate = gate(configEnabled: config.macosSessionPersistence)
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    @Test func configuredOnInAConfigFileLeavesTheGateOpen() throws {
        let config = try TemporaryConfig("macos-session-persistence = true")
        #expect(config.macosSessionPersistence)

        let gate = gate(configEnabled: config.macosSessionPersistence)
        #expect(gate.shouldPersist)
        #expect(gate.shouldApplyOnBoot)
    }

    @Test func defaultConfigEnablesPersistence() throws {
        // No key set: the shipped default is on.
        let config = try TemporaryConfig("")
        #expect(config.macosSessionPersistence)
    }
}
