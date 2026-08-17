import AppKit
import Foundation
import Testing
@testable import Ghostty

struct GhosttyFilesPanelRestorationPreflightTests {
    @Test func roundTripsPersistedPanelState() throws {
        let persisted = FilesPanelPresentationState.Persisted(
            visible: true,
            width: 360,
            rootMode: .pinned,
            pinnedRoot: "/tmp/project",
            showHidden: true
        )
        let state = makeWire(filesPanel: persisted)
        let decoded = try JSONDecoder().decode(
            TerminalRestoreWireSnapshot.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded.filesPanel?.visible == persisted.visible)
        #expect(decoded.filesPanel?.width == persisted.width)
        #expect(decoded.filesPanel?.rootMode == persisted.rootMode.rawValue)
        #expect(decoded.filesPanel?.pinnedRoot == persisted.pinnedRoot)
        #expect(decoded.filesPanel?.showHidden == persisted.showHidden)
    }

    @Test func archiveWithoutPanelFieldDecodesAsNil() throws {
        let data = try JSONEncoder().encode(makeWire(filesPanel: nil))
        let decoded = try JSONDecoder().decode(
            TerminalRestoreWireSnapshot.self,
            from: data
        )
        #expect(decoded.filesPanel == nil)
    }

    private func makeWire(
        filesPanel: FilesPanelPresentationState.Persisted?
    ) -> TerminalRestoreWireSnapshot {
        .init(
            physicalWindowID: UUID().uuidString,
            workspaces: nil,
            selectedWorkspaceID: nil,
            selectedTabID: nil,
            titleOverride: nil,
            fullscreenMode: nil,
            filesPanel: filesPanel.map {
                .init(
                    visible: $0.visible,
                    width: $0.width,
                    rootMode: $0.rootMode.rawValue,
                    pinnedRoot: $0.pinnedRoot,
                    showHidden: $0.showHidden
                )
            }
        )
    }
}
