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
        let state = makeState(filesPanel: persisted)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded.filesPanel == persisted)
    }

    @Test func archiveWithoutPanelFieldDecodesAsNil() throws {
        let data = try JSONEncoder().encode(makeState(filesPanel: nil))
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: data
        )
        #expect(decoded.filesPanel == nil)
    }

    private func makeState(
        filesPanel: FilesPanelPresentationState.Persisted?
    ) -> TerminalRestorableState.InternalState<MockView> {
        .init(
            focusedSurface: nil,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil,
            filesPanel: filesPanel
        )
    }
}
