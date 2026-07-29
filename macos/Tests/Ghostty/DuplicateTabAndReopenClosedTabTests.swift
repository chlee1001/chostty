import AppKit
import Testing
@testable import Ghostty

/// Integration tests for F7 "Duplicate Tab" (`BaseTerminalController.duplicateTab(_:)`)
/// and F8 "Reopen Closed Tab" (`BaseTerminalController.reopenClosedTab()`), built
/// through `TerminalControllerTestHarness` so acceptance can assert what is
/// actually PRESENTED (`presentedSessionID`, the mounted `surfaceTree`) rather
/// than store state alone.
@MainActor
struct DuplicateTabAndReopenClosedTabTests {
    // MARK: - Helpers

    private func makeSession(pwd: String? = nil, titleOverride: String? = nil) -> TerminalSessionState {
        let tree: SplitTree<Ghostty.SurfaceView>
        if let app = TerminalControllerTestHarness.sharedApp.app {
            tree = SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil))
        } else {
            tree = SplitTree<Ghostty.SurfaceView>()
        }
        let session = TerminalSessionState(id: UUID(), surfaceTree: tree)
        session.pwd = pwd
        session.titleOverride = titleOverride
        return session
    }

    private func makeWorkspace(name: String, tabCount: Int) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        return WorkspaceSession(id: UUID(), name: name, tabs: tabs, selectedTabID: tabs.first?.id)
    }

    // MARK: - F7: Duplicate Tab

    @Test func duplicateInsertsImmediatelyAfterSourceAndSelectsIt() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 3)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        ws.tabs[0].pwd = "/tmp/source"
        ws.tabs[0].titleOverride = "Source Title"

        let beforeGeneration = controller.workspaceStore.snapshot.mountGeneration
        let newID = try #require(controller.duplicateTab(ws.tabs[0].id))

        // Inserted at source index + 1.
        let workspace = try #require(controller.workspaceStore.workspace(forTabID: newID))
        #expect(workspace.tabs.map(\.id) == [ws.tabs[0].id, newID, ws.tabs[1].id, ws.tabs[2].id])

        // Selected, +1 generation, and mounted with surfaces.
        #expect(controller.workspaceStore.snapshot.mountGeneration > beforeGeneration)
        #expect(controller.workspaceStore.snapshot.selection.tabID == newID)
        #expect(controller.presentedSessionID == newID)
        #expect(!controller.surfaceTree.isEmpty)

        // Copies pwd and titleOverride from the SOURCE.
        let duplicated = try #require(controller.workspaceStore.session(forTabID: newID))
        #expect(duplicated.titleOverride == "Source Title")

        // Does NOT copy scrollback/process state — it is a brand-new surface.
        #expect(duplicated.surfaceTree.first !== ws.tabs[0].surfaceTree.first)
    }

    @Test func duplicatingNonPresentedTabInNonSelectedWorkspaceSelectsItInTheSourceWorkspace() throws {
        let selectedWs = makeWorkspace(name: "Selected", tabCount: 1)
        let sourceWs = makeWorkspace(name: "Source", tabCount: 2)
        let selection = Selection(workspaceID: selectedWs.id, tabID: selectedWs.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [selectedWs, sourceWs],
            selection: selection))

        // Duplicate the SECOND tab of the non-selected workspace — neither
        // presented nor in the selected workspace.
        let sourceTabID = sourceWs.tabs[1].id
        #expect(controller.presentedSessionID != sourceTabID)
        #expect(controller.workspaceStore.snapshot.selection.workspaceID != sourceWs.id)

        let newID = try #require(controller.duplicateTab(sourceTabID))

        // Selection moves to the SOURCE workspace, not the previously-selected one.
        #expect(controller.workspaceStore.snapshot.selection.workspaceID == sourceWs.id)
        #expect(controller.workspaceStore.snapshot.selection.tabID == newID)
        #expect(controller.presentedSessionID == newID)

        let workspace = try #require(controller.workspaceStore.workspace(forTabID: newID))
        #expect(workspace.id == sourceWs.id)
        #expect(workspace.tabs.map(\.id) == [sourceWs.tabs[0].id, sourceWs.tabs[1].id, newID])
    }

    // MARK: - F8: Reopen Closed Tab

    /// Criterion 1: close then immediately reopen restores the SAME session
    /// id and the SAME live `SurfaceView` identities (the fast path — the
    /// lease is still detached because nothing consumed or finalized it).
    @Test func closeThenImmediatelyReopenRestoresSameSessionAndSurfaceIdentity() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 3)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[1].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        let closedID = ws.tabs[1].id
        let closedSurface = ws.tabs[1].surfaceTree.first

        controller.closeWorkspaceTab(closedID)
        #expect(controller.workspaceStore.session(forTabID: closedID) == nil)
        #expect(controller.closedTabHistory.count == 1)

        controller.reopenClosedTab()

        #expect(controller.closedTabHistory.count == 0)
        #expect(controller.presentedSessionID == closedID)
        let restored = try #require(controller.workspaceStore.workspace(forTabID: closedID))
        // Original index preserved.
        #expect(restored.tabs.map(\.id) == [ws.tabs[0].id, closedID, ws.tabs[2].id])
        // Same live SurfaceView identity, not a fresh surface.
        #expect(controller.surfaceTree.first === closedSurface)
    }

    /// Criterion 4: after forcing `finalize()`, reopen falls back to a fresh
    /// tab restoring pwd/titleOverride/index — never claiming resurrection.
    @Test func reopenAfterForcedFinalizeCreatesFreshTabWithRecordedMetadata() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 2)
        let closingSession = ws.tabs[1]
        closingSession.pwd = "/Users/example"
        closingSession.titleOverride = "Kept Title"
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        controller.closeWorkspaceTab(closingSession.id)
        #expect(controller.closedTabHistory.count == 1)

        // Force the undo grace window to have elapsed for this specific tab.
        controller.closedTabHistory.entries.last?.leaseGroup.finalizeAll()

        controller.reopenClosedTab()

        let restoredWorkspace = try #require(controller.workspaceStore.workspace(forTabID: controller.presentedSessionID ?? UUID()))
        #expect(restoredWorkspace.tabs.count == 2)
        let freshTabID = restoredWorkspace.tabs[1].id
        // NEW session id — never the closed one.
        #expect(freshTabID != closingSession.id)

        let freshSession = try #require(controller.workspaceStore.session(forTabID: freshTabID))
        #expect(freshSession.titleOverride == "Kept Title")
    }

    /// Criterion 5: an entry whose recorded workspace no longer exists lands
    /// in the currently-selected workspace instead of being dropped.
    @Test func reopenIntoAGoneWorkspaceLandsInTheSelectedWorkspace() throws {
        let keepWs = makeWorkspace(name: "Keep", tabCount: 1)
        let doomedWs = makeWorkspace(name: "Doomed", tabCount: 2)
        let selection = Selection(workspaceID: keepWs.id, tabID: keepWs.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [keepWs, doomedWs],
            selection: selection))

        controller.closeWorkspace(doomedWs.id)
        #expect(controller.workspaceStore.snapshot.workspaces.contains { $0.id == doomedWs.id } == false)
        #expect(controller.workspaceStore.snapshot.selection.workspaceID == keepWs.id)

        controller.reopenClosedTab()

        // `doomedWs` no longer exists — the reopened tab(s) must land in the
        // currently-selected workspace instead of being dropped or silently
        // recreating a workspace under the old (now meaningless) id.
        let selectedID = controller.workspaceStore.snapshot.selection.workspaceID
        #expect(selectedID == keepWs.id)
        #expect(controller.workspaceStore.workspace(forTabID: controller.presentedSessionID ?? UUID())?.id == keepWs.id)
        #expect(controller.workspaceStore.allSessions.count == 3)
    }

    /// Criteria 6/7: `closeWorkspace` records exactly ONE group; one reopen
    /// restores every tab with no duplicated id, and history count returns to
    /// its pre-close value.
    @Test func closeWorkspaceRecordsOneGroupAndOneReopenRestoresAllWithNoDuplicateID() throws {
        let ws = makeWorkspace(name: "Doomed", tabCount: 3)
        let originalOrder = ws.tabs.map(\.id)
        let other = makeWorkspace(name: "Other", tabCount: 1)
        let selection = Selection(workspaceID: other.id, tabID: other.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [other, ws],
            selection: selection))

        let preCloseHistoryCount = controller.closedTabHistory.count
        controller.closeWorkspace(ws.id)
        #expect(controller.closedTabHistory.count == preCloseHistoryCount + 1)

        controller.reopenClosedTab()
        #expect(controller.closedTabHistory.count == preCloseHistoryCount)

        let allIDs = controller.workspaceStore.allSessions.map(\.id)
        #expect(Set(allIDs).count == allIDs.count)
        #expect(allIDs.count == 4) // other's 1 tab + ws's 3 tabs, all back.

        // `ws` itself no longer exists (closeWorkspace removes the whole
        // workspace, not just its tabs), so reopen's fallback lands every
        // restored tab in the currently-selected workspace ("other") — but
        // still in `ws`'s ORIGINAL relative order, not close-time order.
        let restoredWorkspace = try #require(
            controller.workspaceStore.snapshot.workspaces.first { $0.id == other.id })
        let restoredWsTabIDs = restoredWorkspace.tabs.map(\.id).filter { originalOrder.contains($0) }
        #expect(restoredWsTabIDs == originalOrder)
    }

    /// Criterion 7 (the grouped-undo regression): closing-other-tabs on a
    /// 3-tab workspace suppresses per-tab history recording (so it does not
    /// pop as 2 separate single entries) and one reopen restores exactly the
    /// 2 closed tabs with no id appearing twice.
    @Test func closeOtherTabsRecordsOneGroupAndReopenRestoresWithoutDuplicateIDs() throws {
        let ws = makeWorkspace(name: "Workspace 1", tabCount: 3)
        let originalOrder = ws.tabs.map(\.id)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        let preCloseHistoryCount = controller.closedTabHistory.count
        controller.closeOtherTabsImmediately()

        #expect(controller.workspaceStore.allSessions.count == 1)
        // Exactly ONE group entry, not 2 single entries.
        #expect(controller.closedTabHistory.count == preCloseHistoryCount + 1)

        controller.reopenClosedTab()

        #expect(controller.workspaceStore.allSessions.count == 3)
        let allIDs = controller.workspaceStore.allSessions.map(\.id)
        #expect(Set(allIDs).count == 3)
        #expect(controller.closedTabHistory.count == preCloseHistoryCount)

        // Grouped reopen must restore the ORIGINAL tab order. Each
        // `closeWorkspaceTab` call inside `closeOtherTabsImmediately`'s loop
        // records its index against an already-shrinking snapshot; without
        // normalizing to the original absolute index this comes back
        // reversed (see `closeOtherTabsImmediately`'s normalization comment).
        let restoredWorkspace = try #require(
            controller.workspaceStore.snapshot.workspaces.first { $0.id == ws.id })
        #expect(restoredWorkspace.tabs.map(\.id) == originalOrder)
    }

    // MARK: Regression found by the Phase 2 red-team pass

    @Test func closeOtherTabsThenUndoThenReopenDoesNotDuplicate() throws {
        let workspaces = [makeWorkspace(name: "Workspace 1", tabCount: 3)]
        let selection = Selection(workspaceID: workspaces[0].id, tabID: workspaces[0].tabs[0].id)
        let controller = try #require(
            TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))
        #expect(controller.workspaceStore.allSessions.count == 3)

        controller.closeOtherTabsImmediately()
        #expect(controller.workspaceStore.allSessions.count == 1)

        // The real Cmd+Z path: one grouped undo restores both closed tabs
        // live, which CONSUMES the very leases the history entry holds.
        controller.undoManager?.undo()
        #expect(controller.workspaceStore.allSessions.count == 3)

        // That entry is now spent. Reopening must recognize it and do nothing,
        // rather than building fresh duplicates of tabs already on screen —
        // this previously produced 5.
        controller.reopenClosedTab()
        #expect(controller.workspaceStore.allSessions.count == 3)

        let ids = controller.workspaceStore.allSessions.map { $0.id }
        #expect(Set(ids).count == ids.count)
    }

    @Test func closeTabsOnTheRightReopensInOriginalOrder() throws {
        let workspaces = [makeWorkspace(name: "Workspace 1", tabCount: 3)]
        let originalOrder = workspaces[0].tabs.map { $0.id }
        // Select the FIRST tab so tabs 2 and 3 are "to the right".
        let selection = Selection(workspaceID: workspaces[0].id, tabID: originalOrder[0])
        let controller = try #require(
            TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))

        controller.closeTabsOnTheRightImmediately()
        #expect(controller.workspaceStore.allSessions.count == 1)

        controller.reopenClosedTab()

        // Indices are captured BEFORE the removal loop shifts them; replaying
        // post-removal indices forward would reopen these reversed.
        let restored = try #require(
            controller.workspaceStore.snapshot.workspaces.first { $0.id == workspaces[0].id })
        #expect(restored.tabs.map { $0.id } == originalOrder)
    }

    /// Architect re-review regression: `closeTabsOnTheRightImmediately(anchoredAt:)`
    /// lets the item menu act on the CLICKED tab, which need not be
    /// `presentedSessionID`. The redo registration used to re-invoke the
    /// zero-argument form, so redo re-resolved the anchor against whatever
    /// tab happened to be presented at redo time instead of the tab the
    /// original action anchored at — closing tabs the user never touched.
    /// Anchor at a NON-presented tab, undo, redo: redo must close the exact
    /// same tab set as the original action, and must never close the anchor
    /// tab itself.
    @Test func closeTabsOnTheRightRedoReanchorsAtOriginalAnchorNotPresented() throws {
        let workspaces = [makeWorkspace(name: "Workspace 1", tabCount: 3)]
        let tabs = workspaces[0].tabs
        // Presented tab is A (tabs[0]); anchor the action at B (tabs[1]),
        // a NON-presented tab, so redo has something to get wrong.
        let selection = Selection(workspaceID: workspaces[0].id, tabID: tabs[0].id)
        let controller = try #require(
            TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))

        controller.closeTabsOnTheRightImmediately(anchoredAt: tabs[1].id)
        #expect(controller.workspaceStore.allSessions.count == 2)
        #expect(controller.workspaceStore.allSessions.map(\.id).contains(tabs[1].id))
        #expect(!controller.workspaceStore.allSessions.map(\.id).contains(tabs[2].id))

        controller.undoManager?.undo()
        #expect(controller.workspaceStore.allSessions.count == 3)

        controller.undoManager?.redo()

        // The anchor tab (B) must survive; only C (to its right) closes again.
        #expect(controller.workspaceStore.allSessions.count == 2)
        let survivingIDs = Set(controller.workspaceStore.allSessions.map(\.id))
        #expect(survivingIDs.contains(tabs[0].id))
        #expect(survivingIDs.contains(tabs[1].id))
        #expect(!survivingIDs.contains(tabs[2].id))
    }

    /// Same regression, for `closeOtherTabsImmediately(anchoredAt:)`: anchor
    /// at a non-presented tab, undo, redo. Redo must close the same tabs
    /// (everyone but the anchor), and must never close the anchor itself.
    @Test func closeOtherTabsRedoReanchorsAtOriginalAnchorNotPresented() throws {
        let workspaces = [makeWorkspace(name: "Workspace 1", tabCount: 3)]
        let tabs = workspaces[0].tabs
        let selection = Selection(workspaceID: workspaces[0].id, tabID: tabs[0].id)
        let controller = try #require(
            TerminalControllerTestHarness.make(workspaces: workspaces, selection: selection))

        controller.closeOtherTabsImmediately(anchoredAt: tabs[1].id)
        #expect(controller.workspaceStore.allSessions.count == 1)
        #expect(controller.workspaceStore.allSessions.first?.id == tabs[1].id)

        controller.undoManager?.undo()
        #expect(controller.workspaceStore.allSessions.count == 3)

        controller.undoManager?.redo()

        #expect(controller.workspaceStore.allSessions.count == 1)
        #expect(controller.workspaceStore.allSessions.first?.id == tabs[1].id)
    }
}
