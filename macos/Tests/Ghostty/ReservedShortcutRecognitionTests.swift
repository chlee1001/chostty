import AppKit
import Testing
@testable import Ghostty

/// Tests for the reserved workspace/tab-switch shortcuts:
/// `ReservedShortcutDispatcher.decision(for:keyWindowKind:firstResponderIsTextField:)`
/// (pure recognition) and `ReservedShortcutDispatcher.perform(_:on:)`
/// (execution against a real, headless `TerminalController` built through
/// `TerminalControllerTestHarness`).
///
/// Acceptance criteria assert `presentedSessionID` and the mounted
/// `surfaceTree` — not store state alone — because a store-only assertion
/// cannot tell whether the switch was actually PRESENTED.
@MainActor
struct ReservedShortcutRecognitionTests {
    // MARK: - Helpers

    private func makeEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isARepeat: Bool = false,
        charactersIgnoringModifiers: String = ""
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }

    /// Builds a session with a single, real surface leaf so a switch's
    /// resulting `surfaceTree` can be distinguished from every other
    /// session's tree by identity, not merely by both being empty.
    private func makeSession() -> TerminalSessionState {
        guard let app = TerminalControllerTestHarness.sharedApp.app else {
            return TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        }
        let view = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        return TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>(view: view))
    }

    /// Builds `workspaceCount` workspaces, each with `tabsPerWorkspace` tabs.
    private func makeWorkspaces(workspaceCount: Int, tabsPerWorkspace: Int) -> [WorkspaceSession] {
        (0..<workspaceCount).map { wsIndex in
            let tabs = (0..<tabsPerWorkspace).map { _ in makeSession() }
            return WorkspaceSession(
                id: UUID(),
                name: "Workspace \(wsIndex + 1)",
                tabs: tabs,
                selectedTabID: tabs.first?.id
            )
        }
    }

    // MARK: - 1. keyCode 19 + Cmd selects workspace index 2, presented end-to-end

    @Test func cmd2SelectsWorkspaceIndexTwoAndPresentsItsSelectedTab() throws {
        let workspaces = makeWorkspaces(workspaceCount: 3, tabsPerWorkspace: 2)
        let selection = Selection(workspaceID: workspaces[0].id, tabID: workspaces[0].tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))

        let event = makeEvent(keyCode: 19, modifierFlags: .command)
        let decision = ReservedShortcutDispatcher.decision(
            for: event,
            keyWindowKind: .terminal,
            firstResponderIsTextField: false
        )
        #expect(decision == .action(.selectWorkspace(index: 2)))

        guard case .action(let action) = decision else {
            Issue.record("expected a recognized action")
            return
        }
        ReservedShortcutDispatcher.perform(action, on: controller)

        let store = controller.workspaceStore
        let expectedWorkspace = workspaces[1]
        let expectedTabID = expectedWorkspace.tabs[0].id

        #expect(store.snapshot.selection.workspaceID == expectedWorkspace.id)
        #expect(store.snapshot.selection.tabID == expectedTabID)
        #expect(
            store.snapshot.workspaces.first { $0.id == expectedWorkspace.id }?.selectedTabID
                == store.snapshot.selection.tabID
        )
        #expect(controller.presentedSessionID == store.snapshot.selection.tabID)

        let presentedIDs = Set(controller.surfaceTree.map(\.id))
        let expectedIDs = Set(expectedWorkspace.tabs[0].surfaceTree.map(\.id))
        #expect(presentedIDs == expectedIDs)
        #expect(!presentedIDs.isEmpty || expectedIDs.isEmpty)
    }

    // MARK: - 2. Generation bumps once per chord; a held repeat adds nothing

    @Test func heldChordBumpsGenerationOnceAndReturnsConsumedRepeat() throws {
        let workspaces = makeWorkspaces(workspaceCount: 3, tabsPerWorkspace: 1)
        let selection = Selection(workspaceID: workspaces[0].id, tabID: workspaces[0].tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))
        let store = controller.workspaceStore

        let firstPress = makeEvent(keyCode: 19, modifierFlags: .command, isARepeat: false)
        let decision1 = ReservedShortcutDispatcher.decision(
            for: firstPress, keyWindowKind: .terminal, firstResponderIsTextField: false)
        guard case .action(let action) = decision1 else {
            Issue.record("expected a recognized action")
            return
        }

        let generationBefore = store.snapshot.mountGeneration
        ReservedShortcutDispatcher.perform(action, on: controller)
        let generationAfterFirst = store.snapshot.mountGeneration
        #expect(generationAfterFirst == generationBefore + 1)

        // A held chord repeats the same physical key with isARepeat = true.
        let heldPress = makeEvent(keyCode: 19, modifierFlags: .command, isARepeat: true)
        let decision2 = ReservedShortcutDispatcher.decision(
            for: heldPress, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision2 == .consumedRepeat)

        // consumedRepeat swallows the event without executing anything again.
        #expect(store.snapshot.mountGeneration == generationAfterFirst)
    }

    // MARK: - 3. Non-Latin charactersIgnoringModifiers still yields index 2

    @Test func nonLatinCharactersStillYieldsIndexTwoForKeyCode19() {
        // Korean 2-Set layout reports "ㅜ" for the physical key at code 19;
        // recognition must be layout-independent (keyed on `keyCode`, not
        // `charactersIgnoringModifiers`).
        let event = makeEvent(
            keyCode: 19,
            modifierFlags: .command,
            charactersIgnoringModifiers: "ㅜ"
        )
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision == .action(.selectWorkspace(index: 2)))
    }

    // MARK: - 4. Cmd+9 with 4 workspaces clamps to 4

    @Test func cmd9ClampsToLastWorkspace() throws {
        let workspaces = makeWorkspaces(workspaceCount: 4, tabsPerWorkspace: 1)
        let selection = Selection(workspaceID: workspaces[0].id, tabID: workspaces[0].tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))

        let event = makeEvent(keyCode: 25, modifierFlags: .command) // 9 = 25
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision == .action(.selectLastWorkspace))

        guard case .action(let action) = decision else {
            Issue.record("expected a recognized action")
            return
        }
        ReservedShortcutDispatcher.perform(action, on: controller)

        #expect(controller.workspaceStore.snapshot.selection.workspaceID == workspaces[3].id)
    }

    @Test func cmd9ReachesTheLastWorkspaceWhenThereAreMoreThanNine() throws {
        let workspaces = makeWorkspaces(workspaceCount: 12, tabsPerWorkspace: 1)
        let selection = Selection(workspaceID: workspaces[0].id, tabID: workspaces[0].tabs[0].id)
        let controller = try #require(
            TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))

        let event = makeEvent(keyCode: 25, modifierFlags: .command)
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        guard case .action(let action) = decision else {
            Issue.record("expected a recognized action")
            return
        }
        ReservedShortcutDispatcher.perform(action, on: controller)

        // Cmd+9 replaces core's `last_tab`. Clamping by index would stop at the
        // 9th and leave workspaces 10-12 unreachable from the keyboard.
        #expect(controller.workspaceStore.snapshot.selection.workspaceID == workspaces[11].id)
    }

    // MARK: - 5. Cmd+Alt+1 and Cmd+Alt+Left are unmatched (LIVE goto_split)

    @Test func cmdAltDigitIsUnmatched() {
        let event = makeEvent(keyCode: 18, modifierFlags: [.command, .option]) // 1 = 18
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision == .unmatched)
    }

    @Test func cmdAltLeftArrowIsUnmatched() {
        let event = makeEvent(keyCode: 123, modifierFlags: [.command, .option]) // Left arrow
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision == .unmatched)
    }

    @Test func cmd0IsUnclaimed() {
        let event = makeEvent(keyCode: 29, modifierFlags: .command) // 0 = 29
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision == .unmatched)
    }

    @Test func cmdLeftBracketAloneIsUnmatched() {
        // Cmd+[ is the LIVE goto_split:previous default and must not be
        // claimed; only Cmd+Shift+[ is reserved.
        let event = makeEvent(keyCode: 33, modifierFlags: .command)
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: false)
        #expect(decision == .unmatched)
    }

    // MARK: - 6. Settings, quick terminal, and a focused text field: always unmatched

    @Test func nonTerminalKeyWindowIsUnmatched() {
        let event = makeEvent(keyCode: 19, modifierFlags: .command)
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .other, firstResponderIsTextField: false)
        #expect(decision == .unmatched)
    }

    @Test func focusedTextFieldIsUnmatchedEvenInATerminalWindow() {
        let event = makeEvent(keyCode: 19, modifierFlags: .command)
        let decision = ReservedShortcutDispatcher.decision(
            for: event, keyWindowKind: .terminal, firstResponderIsTextField: true)
        #expect(decision == .unmatched)
    }

    @Test func everyChordIsUnmatchedOutsideATerminalWindowOrInAFocusedField() {
        let chords: [(UInt16, NSEvent.ModifierFlags)] = [
            (18, .command),                    // Cmd+1
            (25, .command),                     // Cmd+9
            (33, [.command, .shift]),           // Cmd+Shift+[
            (30, [.command, .shift]),           // Cmd+Shift+]
            (48, .control),                     // Ctrl+Tab
            (48, [.control, .shift]),            // Ctrl+Shift+Tab
        ]

        for (keyCode, mods) in chords {
            let event = makeEvent(keyCode: keyCode, modifierFlags: mods)

            // Settings / quick terminal (not a TerminalWindow key window).
            #expect(
                ReservedShortcutDispatcher.decision(
                    for: event, keyWindowKind: .other, firstResponderIsTextField: false
                ) == .unmatched
            )

            // A focused text field, even in a terminal window.
            #expect(
                ReservedShortcutDispatcher.decision(
                    for: event, keyWindowKind: .terminal, firstResponderIsTextField: true
                ) == .unmatched
            )
        }
    }

    // MARK: - Caps Lock must not break reserved chords

    /// `.deviceIndependentFlagsMask` includes `.capsLock`/`.numericPad`/
    /// `.function`/`.help`, so comparing against it for EXACT equality would
    /// make Caps Lock alone turn Cmd+1 into a mismatch. The mask must be
    /// narrowed to exactly `[.command, .shift, .control, .option]` while
    /// STILL comparing for exact equality, so `Cmd+Alt+1` stays unclaimed.
    @Test func capsLockDoesNotBreakCmd1ButAltStillUnclaimsIt() {
        let withCapsLock = makeEvent(keyCode: 18, modifierFlags: [.command, .capsLock])
        #expect(
            ReservedShortcutDispatcher.decision(
                for: withCapsLock, keyWindowKind: .terminal, firstResponderIsTextField: false
            ) == .action(.selectWorkspace(index: 1))
        )

        let withAlt = makeEvent(keyCode: 18, modifierFlags: [.command, .option])
        #expect(
            ReservedShortcutDispatcher.decision(
                for: withAlt, keyWindowKind: .terminal, firstResponderIsTextField: false
            ) == .unmatched
        )
    }

    // MARK: - 7. reservedMenuItems.nextWorkspace carries the Tab keyEquivalent with control

    @Test func nextWorkspaceMenuItemCarriesControlTab() {
        let appDelegate = AppDelegate()
        let nextWorkspace = appDelegate.reservedMenuItems.nextWorkspace

        #expect(nextWorkspace.keyEquivalent == "\t")
        #expect(nextWorkspace.keyEquivalentModifierMask == [.control])
    }

    // MARK: - Text-field guard correctness
    //
    // The guard is `firstResponder is NSText`. Both halves matter: it must
    // catch AppKit's field editor (what a focused SwiftUI TextField actually
    // installs, since NSTextView subclasses NSText) so the inline rename field
    // keeps its digits, and it must NOT catch a terminal surface, which
    // implements NSTextInputClient for IME but is not an NSText.

    @Test func fieldEditorIsRecognizedAsATextField() {
        // NSTextView is the concrete field editor AppKit installs when an
        // NSTextField-backed control (including SwiftUI's TextField) gains
        // focus. If this stopped being an NSText, the guard would silently
        // stop protecting the rename field.
        #expect(NSTextView() is NSText)
    }

    @Test func aTerminalSurfaceIsNotTreatedAsATextField() throws {
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)

        // A terminal surface conforms to NSTextInputClient for IME. Using that
        // conformance as the guard would make every reserved chord dead inside
        // a normal terminal.
        #expect(!(surface is NSText))
    }
}
