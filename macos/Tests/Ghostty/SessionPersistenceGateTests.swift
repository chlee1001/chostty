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

    @Test func applePersistenceArgumentsSkipBootRestoreButStillPersist() {
        let gate = gate(arguments: ["-ApplePersistenceIgnoreState", "YES"])
        #expect(gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
    }

    @Test func explicitOpenIntentSkipsBootRestoreButStillPersists() {
        // `ghostty -e ...`, `open --args`: the user asked for something
        // specific, so last session's layout must not land on top, but what
        // this launch opens is still the session the user is using.
        for arguments in [["-e", "top"], ["--config-file=/tmp/x"]] {
            let gate = gate(arguments: arguments)
            #expect(gate.shouldPersist)
            #expect(!gate.shouldApplyOnBoot)
        }
    }

    @Test func explicitOpenIntentNeverReopensAClosedGate() {
        let gate = gate(
            environment: [SessionPersistenceGate.killSwitchVariable: "1"],
            arguments: ["-e", "top"]
        )
        #expect(!gate.shouldPersist)
        #expect(!gate.shouldApplyOnBoot)
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
