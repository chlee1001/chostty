import AppKit
import Testing
@testable import Ghostty
@testable import GhosttyKit

/// Tests for `AppDelegate.reservedChordCollisions(config:)`, the config-reload
/// collision walk (PM-3's only mitigation for F1): a user keybind on a chord
/// that F1 (`ReservedShortcutDispatcher`) or the app-level router
/// (`TerminalCommandRouter`) treat as reserved product behavior is silently
/// swallowed by `AppDelegate.localEventKeyDown`, BEFORE
/// `ghostty_config_key_is_binding` ever runs. This walk cannot un-swallow the
/// chord — it only detects and surfaces the collision so it can be logged.
@MainActor
struct ReservedChordCollisionTests {
    @Test func detectsAUserKeybindOnAReservedChord() throws {
        // Ctrl+Shift+Tab bound to an arbitrary action is unambiguously a
        // collision with F1's reserved previous-workspace chord.
        let config = try TemporaryConfig("keybind = ctrl+shift+tab=new_window")
        let appDelegate = AppDelegate()

        let collisions = appDelegate.reservedChordCollisions(config: config)
        #expect(collisions.contains("Ctrl+Shift+Tab"))
    }

    /// Ghostty's own default core keybinds already claim several reserved
    /// chords (e.g. `goto_tab:N` on Cmd+1…9) — that pre-existing collision is
    /// exactly the defect PM-3 exists to surface, not a corner case the walk
    /// should special-case away. An empty config must still report it.
    @Test func defaultCoreKeybindsAlreadyCollideWithCmd1Through9() throws {
        let config = try TemporaryConfig("")
        let appDelegate = AppDelegate()

        let collisions = appDelegate.reservedChordCollisions(config: config)
        for n in 1...9 {
            #expect(collisions.contains("Cmd+\(n)"))
        }
    }
}
