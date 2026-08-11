import AppKit
import Testing
@testable import Ghostty

@MainActor
struct FilesPanelQuickLookTests {
    @Test func spaceKeyInvokesResponderAction() throws {
        var invocationCount = 0
        let responder = FilesPanelQuickLookResponderView.ResponderView {
            invocationCount += 1
            return true
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        responder.keyDown(with: event)

        #expect(invocationCount == 1)
    }

    @Test func spaceKeyEquivalentConsumesOnlyWhenPreviewHandlesIt() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        #expect(FilesPanelQuickLookResponderView.ResponderView { true }
            .performKeyEquivalent(with: event))
        #expect(!FilesPanelQuickLookResponderView.ResponderView { false }
            .performKeyEquivalent(with: event))
    }
}
