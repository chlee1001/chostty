import AppKit
import Combine
import SwiftUI
import Testing
@testable import Ghostty

/// Tests for `TerminalCommandPaletteView.workspaceCommandOptions(store:perform:)`.
///
/// Built through `TerminalControllerTestHarness` so invocation can assert
/// what is actually PRESENTED (`presentedSessionID`, the mounted
/// `surfaceTree`), not just the store's desired selection, and so the
/// entries' actions can be routed through `TerminalCommandPaletteView.perform`
/// — the SAME production dispatcher the live command palette uses — rather
/// than a bespoke test-only stand-in.
@MainActor
struct CommandPaletteWorkspaceOptionsTests {
    private func makeSession() -> TerminalSessionState {
        let tree: SplitTree<Ghostty.SurfaceView>
        if let app = TerminalControllerTestHarness.sharedApp.app {
            tree = SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil))
        } else {
            tree = SplitTree<Ghostty.SurfaceView>()
        }
        return TerminalSessionState(id: UUID(), surfaceTree: tree)
    }

    private func makeWorkspace(name: String, tabCount: Int, color: TerminalTabColor = .none) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        var ws = WorkspaceSession(id: UUID(), name: name, tabs: tabs, selectedTabID: tabs.first?.id)
        ws.color = color
        return ws
    }

    /// A 3x2 hierarchy (3 workspaces, 2 tabs each) yields at least 3 switch
    /// entries, in snapshot order, carrying each workspace's own color.
    ///
    /// The fixture is created in a deliberately NON-alphabetical order
    /// (Charlie, Alpha, Bravo) so this assertion can actually distinguish
    /// snapshot order from alphabetical order — an alphabetical fixture would
    /// pass under either ordering and prove nothing. This asserts the raw
    /// `workspaceCommandOptions(store:perform:)` provider in isolation, which
    /// does not sort; the composed `commandOptions` the live palette actually
    /// displays re-sorts every option alphabetically by title afterwards
    /// (see `TerminalCommandPaletteView.commandOptions`), so end users still
    /// see alphabetical order on screen.
    @Test func threeByTwoYieldsSwitchEntriesInSnapshotOrderWithColors() throws {
        let ws1 = makeWorkspace(name: "Charlie", tabCount: 2, color: .purple)
        let ws2 = makeWorkspace(name: "Alpha", tabCount: 2, color: .blue)
        let ws3 = makeWorkspace(name: "Bravo", tabCount: 2, color: .green)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2, ws3],
            selection: selection))

        let options = TerminalCommandPaletteView.workspaceCommandOptions(
            store: controller.workspaceStore
        ) { _ in }

        let switchEntries = options.filter { $0.title.hasPrefix("Switch to: ") }
        #expect(switchEntries.count >= 3)

        // Snapshot (workspace-then-tab) order, not alphabetical: Charlie
        // (created first) leads, even though it sorts last alphabetically.
        #expect(switchEntries.map(\.title) == [
            "Switch to: Charlie",
            "Switch to: Alpha",
            "Switch to: Bravo",
        ])

        // Each entry's leadingColor matches its OWN workspace's color.
        #expect(switchEntries[0].leadingColor == TerminalTabColor.purple.displayColor.map { Color($0) })
        #expect(switchEntries[1].leadingColor == TerminalTabColor.blue.displayColor.map { Color($0) })
        #expect(switchEntries[2].leadingColor == TerminalTabColor.green.displayColor.map { Color($0) })

        // Plus the four workspace-scoped actions.
        #expect(options.contains { $0.title == "New Workspace" })
        #expect(options.contains { $0.title == "Rename Workspace" })
        #expect(options.contains { $0.title == "Duplicate Tab" })
        #expect(options.contains { $0.title == "Reopen Closed Tab" })
    }

    /// Invoking a switch entry through `TerminalCommandPaletteView.perform`
    /// (the same dispatcher the live palette uses) gives exactly one
    /// snapshot emission, one generation bump, a valid selection pair, and
    /// `presentedSessionID` on the target with its surfaces mounted.
    @Test func invokingSwitchEntryPresentsExactlyOnce() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 1)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 1)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))

        var performedActions: [TerminalCommandPaletteView.WorkspaceCommandAction] = []
        let options = TerminalCommandPaletteView.workspaceCommandOptions(
            store: controller.workspaceStore
        ) { action in
            performedActions.append(action)
            TerminalCommandPaletteView.perform(action, on: controller)
        }

        let targetEntry = try #require(options.first { $0.title == "Switch to: Bravo" })

        var events = 0
        let cancellable = controller.workspaceStore.$snapshot.dropFirst().sink { _ in events += 1 }
        defer { cancellable.cancel() }
        let beforeGeneration = controller.workspaceStore.snapshot.mountGeneration

        targetEntry.action()

        #expect(performedActions.count == 1)
        #expect(events == 1)
        #expect(controller.workspaceStore.snapshot.mountGeneration == beforeGeneration + 1)

        let selectionAfter = controller.workspaceStore.snapshot.selection
        #expect(selectionAfter.workspaceID == ws2.id)
        #expect(selectionAfter.tabID == ws2.tabs[0].id)
        #expect(controller.presentedSessionID == ws2.tabs[0].id)
        #expect(!controller.surfaceTree.isEmpty)
    }

    /// "Duplicate Tab" routes through the SAME real
    /// `BaseTerminalController.duplicateTab(_:)` path the duplicate-tab tests exercise —
    /// never a bespoke command-palette-only implementation.
    @Test func duplicateTabEntryReachesRealDuplicateTabPath() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 2)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        let options = TerminalCommandPaletteView.workspaceCommandOptions(
            store: controller.workspaceStore
        ) { action in
            TerminalCommandPaletteView.perform(action, on: controller)
        }
        let duplicateEntry = try #require(options.first { $0.title == "Duplicate Tab" })

        let beforeCount = controller.workspaceStore.allSessions.count
        duplicateEntry.action()

        #expect(controller.workspaceStore.allSessions.count == beforeCount + 1)
        // Newly duplicated tab is inserted right after the source and selected.
        #expect(controller.workspaceStore.workspace(forTabID: controller.presentedSessionID ?? UUID())?.id == ws.id)
    }
}
