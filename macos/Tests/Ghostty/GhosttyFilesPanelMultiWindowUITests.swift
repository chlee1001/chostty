import Testing
@testable import Ghostty

@MainActor
struct GhosttyFilesPanelMultiWindowUITests {
    @Test func presentationStateIsIsolatedPerPhysicalWindowController() {
        let first = FilesPanelController(
            seed: .init(
                visible: false,
                width: 280,
                rootMode: .followPWD,
                pinnedRoot: nil,
                showHidden: false
            ),
            watchBroker: .init()
        )
        let second = FilesPanelController(
            seed: .init(
                visible: true,
                width: 360,
                rootMode: .pinned,
                pinnedRoot: "/tmp/second",
                showHidden: true
            ),
            watchBroker: .init()
        )

        first.toggleVisible()
        first.presentation.width = 420
        first.pin(root: "/tmp/first")

        #expect(second.presentation.visible)
        #expect(second.presentation.width == 360)
        #expect(second.presentation.rootMode == .pinned)
        #expect(second.presentation.pinnedRoot == "/tmp/second")
        #expect(second.presentation.showHidden)
    }
}
