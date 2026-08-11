import Foundation
import Testing

struct QuickTerminalCapabilityExclusionTests {
    @Test func onlyOrdinaryTerminalControllerOverridesFilesPanelCapability() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let base = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/Features/Terminal/BaseTerminalController.swift"),
            encoding: .utf8
        )
        let terminal = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/Features/Terminal/TerminalController.swift"),
            encoding: .utf8
        )
        let quick = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/Features/QuickTerminal/QuickTerminalController.swift"),
            encoding: .utf8
        )

        #expect(base.contains("var filesPanelController: FilesPanelController? { nil }"))
        #expect(terminal.contains("override var filesPanelController: FilesPanelController?"))
        #expect(!quick.contains("filesPanelController"))
    }
}
