import AppKit
import Testing
@testable import Ghostty

@MainActor
struct FilesPanelQuickLookResponderViewTests {
    @Test func responderDoesNotStealTerminalFocus() {
        let responder = FilesPanelQuickLookResponderView.ResponderView { false }
        #expect(!responder.acceptsFirstResponder)
    }

    @Test func nonSpaceKeyFallsThroughWithoutInvokingPreview() throws {
        var invoked = false
        let responder = FilesPanelQuickLookResponderView.ResponderView {
            invoked = true
            return true
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        responder.keyDown(with: event)

        #expect(!invoked)
    }
}
