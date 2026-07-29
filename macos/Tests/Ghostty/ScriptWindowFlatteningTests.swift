import AppKit
import Testing
@testable import Ghostty

/// Tests for the F3 Phase 5 AppleScript flattening contract:
///
/// - `window` = one physical controller (`ScriptWindow`).
/// - `tab` = one VIRTUAL tab, enumerated EXACTLY as
///   `WorkspaceSessionStore.allSessions` — workspace, then tab within it —
///   so scripting order and persistence order can never diverge.
/// - `workspace name` (sdef `GTwN`) is a read-only membership label on `tab`;
///   there is no `workspace` scripting class.
/// - `select tab` / `close tab` scope to the ADDRESSED tab, never whatever
///   the controller happens to have presented.
///
/// Built through `TerminalControllerTestHarness` so assertions can check what
/// is actually PRESENTED (`presentedSessionID`, mounted `surfaceTree`), not
/// just the store's desired selection.
@MainActor
struct ScriptWindowFlatteningTests {
    private func makeSession() -> TerminalSessionState {
        let tree: SplitTree<Ghostty.SurfaceView>
        if let app = TerminalControllerTestHarness.sharedApp.app {
            tree = SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil))
        } else {
            tree = SplitTree<Ghostty.SurfaceView>()
        }
        return TerminalSessionState(id: UUID(), surfaceTree: tree)
    }

    private func makeWorkspace(name: String, tabCount: Int) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        return WorkspaceSession(id: UUID(), name: name, tabs: tabs, selectedTabID: tabs.first?.id)
    }

    /// 2 workspaces x 2 tabs in ONE window gives 4 tabs (pre-flattening: 1).
    @Test func twoByTwoInOneWindowGivesFourTabs() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 2)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 2)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))

        let scriptWindow = ScriptWindow(primaryController: controller)
        #expect(scriptWindow.tabs.count == 4)
    }

    /// `ScriptWindow.tabs` order matches `allSessions` EXACTLY — workspace,
    /// then tab within it — never any other ordering.
    @Test func tabEnumerationOrderMatchesAllSessions() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 2)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 2)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))

        let expectedIDs = controller.workspaceStore.allSessions.map { ScriptTab.stableID(session: $0) }
        let actualIDs = ScriptWindow(primaryController: controller).tabs.map(\.idValue)
        #expect(actualIDs == expectedIDs)
    }

    /// `workspace name of tab 3` (1-based) equals the SECOND workspace's
    /// name, and `index` is 1-based over the flattened enumeration.
    @Test func workspaceNameAndOneBasedIndexOfThirdTab() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 2)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 2)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))

        // Keep the `ScriptWindow` alive for the duration of this test:
        // `ScriptTab` holds it only weakly (mirroring how AppleScript object
        // specifiers are re-resolved rather than retained), so an inline
        // temporary would deallocate before `index`/`selected` are read.
        let scriptWindow = ScriptWindow(primaryController: controller)
        let tabs = scriptWindow.tabs
        #expect(tabs.count == 4)

        // Tab 3 (1-based) is `ws2.tabs[0]` — the first tab of the SECOND workspace.
        let tab3 = tabs[2]
        #expect(tab3.workspaceName == ws2.name)
        #expect(tab3.index == 3)

        // Every tab reports its own 1-based position.
        for (offset, tab) in tabs.enumerated() {
            #expect(tab.index == offset + 1)
        }
    }

    /// `selected` compares against `selection.tabID`, not merely which tab
    /// happens to be mounted.
    @Test func selectedComparesAgainstSelectionTabID() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 3)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[1].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        let scriptWindow = ScriptWindow(primaryController: controller)
        let tabs = scriptWindow.tabs
        #expect(tabs[0].selected == false)
        #expect(tabs[1].selected == true)
        #expect(tabs[2].selected == false)

        // Diverge `selection.tabID` from `presentedSessionID`:
        // `WorkspaceSessionStore.selectTab` only updates the store's desired
        // selection, it does NOT mount/present anything (that's
        // `controller.selectSession`'s job). This proves `selected` genuinely
        // compares against `selection.tabID` rather than whatever the
        // controller happens to have mounted — a `selected` implementation
        // that compared against `presentedSessionID` instead would leave the
        // OLD tab reporting `selected == true` here, since `presentedSessionID`
        // never changes.
        #expect(controller.presentedSessionID == ws.tabs[1].id)
        controller.workspaceStore.selectTab(ws.tabs[2].id)
        #expect(controller.presentedSessionID == ws.tabs[1].id)
        #expect(controller.workspaceStore.snapshot.selection.tabID == ws.tabs[2].id)

        let tabsAfter = scriptWindow.tabs
        #expect(tabsAfter[1].selected == false)
        #expect(tabsAfter[2].selected == true)
    }

    /// `focused terminal of tab N` resolves even while tab N is NOT the
    /// controller's presented tab, and the returned object is genuinely
    /// usable — re-resolvable through the app-level `terminals` collection
    /// Cocoa scripting actually uses to rebuild object specifiers, not merely
    /// non-nil while being practically unusable.
    @Test func focusedTerminalResolvesForNonPresentedTab() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 2)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 2)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))
        #expect(controller.presentedSessionID == ws1.tabs[0].id)

        let scriptWindow = ScriptWindow(primaryController: controller)

        // Window-level analogue of the 4-vs-1 tab assertion: every virtual
        // tab's terminal surfaces are reachable through `terminals`, not just
        // the presented tab's.
        #expect(scriptWindow.terminals.count == 4)

        let ws2TabID = ScriptTab.stableID(session: ws2.tabs[0])
        let tab2 = try #require(scriptWindow.tabs.first { $0.idValue == ws2TabID })
        #expect(tab2.selected == false)

        let focused = try #require(tab2.focusedTerminal)

        // Window-scoped, deliberately NOT `NSApp.valueInTerminals`. That walks
        // EVERY controller in `NSApp.windows`, and the harness leaks a window
        // per constructed controller by design (closing them tears down a
        // prior test's sessions and crashed the host). Across the full suite
        // that walk grows with every earlier test until the runner hangs —
        // even though this suite passes in isolation. The window-scoped
        // lookup proves the same thing, that the specifier re-resolves,
        // without depending on what other suites left behind.
        let roundTripped = try #require(scriptWindow.valueInTerminals(uniqueID: focused.stableID))
        #expect(roundTripped.stableID == focused.stableID)
    }

    /// `select tab` presents the ADDRESSED tab through the single mounting
    /// entry point (one generation bump, a valid selection pair, and
    /// `presentedSessionID` on the target) — not merely bring the window
    /// forward while leaving the presented tab unchanged.
    @Test func selectTabPresentsTheAddressedTab() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 1)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 1)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))

        let ws2TabID = ScriptTab.stableID(session: ws2.tabs[0])
        let targetTab = try #require(ScriptWindow(primaryController: controller).tabs.first { $0.idValue == ws2TabID })

        let beforeGeneration = controller.workspaceStore.snapshot.mountGeneration
        _ = targetTab.handleSelectTab(NSScriptCommand())

        #expect(controller.workspaceStore.snapshot.mountGeneration == beforeGeneration + 1)
        let selectionAfter = controller.workspaceStore.snapshot.selection
        #expect(selectionAfter.workspaceID == ws2.id)
        #expect(selectionAfter.tabID == ws2.tabs[0].id)
        #expect(controller.presentedSessionID == ws2.tabs[0].id)
        #expect(!controller.surfaceTree.isEmpty)
    }

    /// `close tab` closes the ADDRESSED tab, never the controller's
    /// presented tab — even when addressed at a NON-presented tab.
    @Test func closeTabClosesTheAddressedTabNotThePresentedOne() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 3)
        // Presented tab is tabs[0]; address tabs[2], a NON-presented tab.
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))
        #expect(controller.presentedSessionID == ws.tabs[0].id)

        let targetStableID = ScriptTab.stableID(session: ws.tabs[2])
        let targetTab = try #require(ScriptWindow(primaryController: controller).tabs.first { $0.idValue == targetStableID })

        _ = targetTab.handleCloseTab(NSScriptCommand())

        // The ADDRESSED tab is gone.
        #expect(controller.workspaceStore.session(forTabID: ws.tabs[2].id) == nil)
        // The PRESENTED tab is untouched — the prior implementation always
        // closed whatever was presented regardless of the addressed tab.
        #expect(controller.workspaceStore.session(forTabID: ws.tabs[0].id) != nil)
        #expect(controller.presentedSessionID == ws.tabs[0].id)
        #expect(controller.workspaceStore.allSessions.count == 2)
    }
}
