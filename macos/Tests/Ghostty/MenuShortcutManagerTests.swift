import AppKit
import Foundation
import Testing
@testable import Ghostty

struct MenuShortcutManagerTests {
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/779", id: 779))
    func unbindShouldDiscardDefault() async throws {
        let config = try TemporaryConfig("keybind = super+d=unbind")

        let item = NSMenuItem(title: "Split Right", action: #selector(BaseTerminalController.splitRight(_:)), keyEquivalent: "d")
        item.keyEquivalentModifierMask = .command
        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        try config.reload("")

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11396", id: 11396))
    func overrideDefault() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")

        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()

        await manager.syncMenuShortcut(config, action: nil, menuItem: hideItem)
        await manager.syncMenuShortcut(config, action: "goto_split:left", menuItem: goToLeftItem)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)
    }

    // MARK: - P2: Undo/Reopen menu pin (`AppDelegate.pinUndoShortcut`/`pinReopenShortcut`)

    /// `undo`'s config binding is `performable`, so it is never painted from
    /// the reverse lookup (`syncMenuShortcut` always clears it). Pinning
    /// must land Edit▸Undo on Cmd+Z and Reopen Closed Tab on the DISTINCT
    /// Cmd+Shift+T unconditionally, regardless of what the config's reverse
    /// lookup would otherwise have painted.
    @MainActor
    @Test func undoAndReopenPinDistinctChords() {
        let undoItem = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "")
        // Simulate `syncMenuShortcut` having just cleared it, per the bug.
        undoItem.keyEquivalent = ""
        undoItem.keyEquivalentModifierMask = []
        AppDelegate.pinUndoShortcut(on: undoItem)
        #expect(undoItem.keyEquivalent == "z")
        #expect(undoItem.keyEquivalentModifierMask == .command)

        let reopenItem = NSMenuItem(title: "Reopen Closed Tab", action: nil, keyEquivalent: "")
        AppDelegate.pinReopenShortcut(on: reopenItem)
        #expect(reopenItem.keyEquivalent == "t")
        #expect(reopenItem.keyEquivalentModifierMask == [.command, .shift])
    }
}
