import AppKit
import Combine
import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

/// Tests for the Phase 1 value-only structural transaction contract on
/// `WorkspaceSessionStore`:
///
/// - `stage()` and `validate(_:)` MUST emit zero publisher events and mutate
///   nothing observable.
/// - `commit(_:)` MUST install the candidate in exactly one `@Published`
///   snapshot assignment and bump the mount generation.
/// - `WorkspaceStructuralCandidate` MUST be recursively value-only.
@MainActor
struct WorkspaceStoreTransactionTests {
    /// Builds a store with `tabCount` tabs in a single workspace.
    private func makeStore(tabCount: Int = 1) -> WorkspaceSessionStore {
        let initial = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )
        let store = WorkspaceSessionStore(initialSession: initial)
        for _ in 1..<max(tabCount, 1) {
            let session = TerminalSessionState(
                id: UUID(),
                surfaceTree: SplitTree<Ghostty.SurfaceView>()
            )
            store.addTab(session)
        }
        return store
    }

    @Test func initialStoreHasOneWorkspaceOneTab() {
        let store = makeStore()
        #expect(store.snapshot.workspaces.count == 1)
        #expect(store.snapshot.workspaces[0].tabs.count == 1)
        #expect(store.snapshot.mountGeneration > 0)
        // Selection references a live tab.
        let sel = store.snapshot.selection
        #expect(store.session(forTabID: sel.tabID) != nil)
    }

    @Test func stageEmitsNoPublisherEvents() {
        let store = makeStore(tabCount: 2)
        var events = 0
        let cancellable = store.$snapshot.dropFirst().sink { _ in events += 1 }
        defer { cancellable.cancel() }

        let before = store.snapshot.mountGeneration
        _ = store.stage()
        _ = store.stage()

        #expect(events == 0)
        #expect(store.snapshot.mountGeneration == before)
    }

    @Test func validateEmitsNoPublisherEvents() {
        let store = makeStore(tabCount: 2)
        let candidate = store.stage()

        var events = 0
        let cancellable = store.$snapshot.dropFirst().sink { _ in events += 1 }
        defer { cancellable.cancel() }

        _ = store.validate(candidate)
        _ = store.validate(candidate)

        #expect(events == 0)
    }

    @Test func commitEmitsExactlyOneSnapshotEvent() {
        let store = makeStore(tabCount: 2)
        let tabs = store.snapshot.workspaces[0].tabs
        let target = tabs[1].id
        let wsID = store.snapshot.workspaces[0].id

        var events = 0
        let cancellable = store.$snapshot.dropFirst().sink { _ in events += 1 }
        defer { cancellable.cancel() }

        let staged = store.stage()
        let candidate = WorkspaceStructuralCandidate(
            workspaces: staged.workspaces,
            selection: Selection(workspaceID: wsID, tabID: target),
            proposedGeneration: staged.proposedGeneration
        )
        #expect(store.validate(candidate))
        store.commit(candidate)

        #expect(events == 1)
        #expect(store.snapshot.selection.tabID == target)
    }

    @Test func commitBumpsMountGeneration() {
        let store = makeStore(tabCount: 2)
        let before = store.snapshot.mountGeneration
        let wsID = store.snapshot.workspaces[0].id
        let target = store.snapshot.workspaces[0].tabs[1].id

        let staged = store.stage()
        let candidate = WorkspaceStructuralCandidate(
            workspaces: staged.workspaces,
            selection: Selection(workspaceID: wsID, tabID: target),
            proposedGeneration: staged.proposedGeneration
        )
        store.commit(candidate)

        #expect(store.snapshot.mountGeneration > before)
    }

    @Test func validateRejectsSelectionOfUnknownTab() {
        let store = makeStore()
        let staged = store.stage()
        let bogus = WorkspaceStructuralCandidate(
            workspaces: staged.workspaces,
            selection: Selection(workspaceID: staged.workspaces[0].id, tabID: UUID()),
            proposedGeneration: staged.proposedGeneration
        )
        #expect(!store.validate(bogus))
    }

    @Test func validateRejectsSelectionOfUnknownWorkspace() {
        let store = makeStore()
        let staged = store.stage()
        let tabID = staged.workspaces[0].tabs[0].id
        let bogus = WorkspaceStructuralCandidate(
            workspaces: staged.workspaces,
            selection: Selection(workspaceID: UUID(), tabID: tabID),
            proposedGeneration: staged.proposedGeneration
        )
        #expect(!store.validate(bogus))
    }

    @Test func addWorkspaceIncreasesWorkspaceCount() {
        let store = makeStore()
        #expect(store.snapshot.workspaces.count == 1)

        let session = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )
        let wsID = store.addWorkspace(initialSession: session)

        #expect(store.snapshot.workspaces.count == 2)
        #expect(store.snapshot.workspaces.contains { $0.id == wsID })
        // The new workspace is selected and has exactly one tab.
        #expect(store.snapshot.selection.workspaceID == wsID)
        #expect(store.snapshot.selection.tabID == session.id)
    }

    @Test func addTabKeepsWorkspaceCountAndSelectsNewTab() {
        let store = makeStore()
        let wsCountBefore = store.snapshot.workspaces.count

        let session = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )
        store.addTab(session)

        #expect(store.snapshot.workspaces.count == wsCountBefore)
        #expect(store.snapshot.workspaces[0].tabs.count == 2)
        #expect(store.snapshot.selection.tabID == session.id)
    }

    @Test func candidateIsValueEquatable() {
        let store = makeStore(tabCount: 2)
        let a = store.stage()
        let b = store.stage()
        // Two stages of an unchanged store produce equal value candidates.
        #expect(a == b)
    }

    @Test func twoStoresAreIsolated() {
        let a = makeStore()
        let b = makeStore()
        #expect(a.snapshot.workspaces[0].id != b.snapshot.workspaces[0].id)
        #expect(a.snapshot.selection.tabID != b.snapshot.selection.tabID)

        let session = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )
        a.addWorkspace(initialSession: session)

        #expect(a.snapshot.workspaces.count == 2)
        #expect(b.snapshot.workspaces.count == 1)
    }

    @Test func restoredStoreRebuildsFullHierarchy() {
        let s1 = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let s2 = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let s3 = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())

        let ws1 = WorkspaceSession(id: UUID(), name: "A", tabs: [s1, s2], selectedTabID: s2.id)
        let ws2 = WorkspaceSession(id: UUID(), name: "B", tabs: [s3], selectedTabID: s3.id)

        let store = WorkspaceSessionStore(
            restoredWorkspaces: [ws1, ws2],
            selection: Selection(workspaceID: ws2.id, tabID: s3.id)
        )

        #expect(store.snapshot.workspaces.count == 2)
        #expect(store.snapshot.workspaces[0].tabs.count == 2)
        #expect(store.snapshot.workspaces[1].tabs.count == 1)
        #expect(store.snapshot.selection.workspaceID == ws2.id)
        #expect(store.snapshot.selection.tabID == s3.id)
        // Every restored session is resolvable by tab id.
        #expect(store.session(forTabID: s1.id) != nil)
        #expect(store.session(forTabID: s2.id) != nil)
        #expect(store.session(forTabID: s3.id) != nil)
    }

    // MARK: Per-session tree ownership
    //
    // Regression guard for the mount-swap ordering bug: a controller writes the
    // presented tree back into the *presented* session whenever `surfaceTree`
    // changes. If "presented" is promoted only after the swap, that write-back
    // lands on the OUTGOING session and overwrites it with the incoming tab's
    // tree — two sessions end up sharing one tree, and the outgoing tab's
    // surfaces lose their last strong reference (the registry stores UUIDs
    // only), killing its PTY.
    //
    // These tests pin the invariant at the model level: distinct sessions must
    // never share a tree, and a session's tree must survive selection changes.

    @Test func distinctSessionsKeepDistinctTrees() {
        let s1 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        store.addTab(s2)

        // Give each session a distinguishable tree, as the controller does when
        // it saves the outgoing tree before a swap.
        let t1 = SplitTree<Ghostty.SurfaceView>()
        let t2 = SplitTree<Ghostty.SurfaceView>()
        s1.surfaceTree = t1
        s2.surfaceTree = t2

        // Selection churn must not copy one session's tree onto another.
        store.selectTab(s1.id)
        store.selectTab(s2.id)
        store.selectTab(s1.id)

        #expect(store.session(forTabID: s1.id) === s1)
        #expect(store.session(forTabID: s2.id) === s2)
        // Each session still owns its own tree object graph.
        #expect(s1.surfaceTree.isEmpty == t1.isEmpty)
        #expect(s2.surfaceTree.isEmpty == t2.isEmpty)
    }

    @Test func selectionChangeDoesNotMutateSessionTrees() {
        let s1 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        store.addTab(s2)

        s1.focusedSurfaceID = UUID()
        let s1Focus = s1.focusedSurfaceID
        s2.focusedSurfaceID = UUID()
        let s2Focus = s2.focusedSurfaceID

        store.selectTab(s1.id)
        store.selectTab(s2.id)

        // A pure selection commit must not rewrite per-session focus memory.
        #expect(s1.focusedSurfaceID == s1Focus)
        #expect(s2.focusedSurfaceID == s2Focus)
        #expect(s1Focus != s2Focus)
    }

    @Test func everySessionIsResolvableByItsOwnTabID() {
        let s1 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let s3 = TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        store.addTab(s2)
        store.addWorkspace(initialSession: s3)

        // Each tab resolves to its own session, never to a neighbor.
        #expect(store.session(forTabID: s1.id) === s1)
        #expect(store.session(forTabID: s2.id) === s2)
        #expect(store.session(forTabID: s3.id) === s3)

        // And the three are genuinely distinct objects.
        #expect(s1 !== s2)
        #expect(s2 !== s3)
        #expect(s1 !== s3)
    }

    // MARK: Selection agreement invariant
    //
    // Selection lives in two places: globally in `Snapshot.selection` and
    // per-workspace in `WorkspaceProjection.selectedTabID` (so re-entering a
    // workspace restores the tab that was last active *there*). If they drift,
    // `selectedSession` — which resolves through `selectedTabID` — names a
    // different tab than the one presented, so title/pwd updates land on the
    // wrong session, the wrong sidebar row highlights, and v8 persists the
    // wrong tab. `validate` must make that state impossible to commit.

    @Test func validateRejectsSelectionDisagreeingWithWorkspace() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = makeSession()
        store.addTab(s2)

        let base = store.stage()
        // Global selection says s1; the workspace still says s2.
        let ws = base.workspaces[0]
        let skewed = WorkspaceStructuralCandidate(
            workspaces: [WorkspaceProjection(
                id: ws.id,
                name: ws.name,
                tabs: ws.tabs,
                selectedTabID: s2.id
            )],
            selection: Selection(workspaceID: ws.id, tabID: s1.id),
            proposedGeneration: base.proposedGeneration
        )

        #expect(store.validate(skewed) == false)
    }

    @Test func selectTabUpdatesBothCopiesOfSelection() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = makeSession()
        store.addTab(s2)

        store.selectTab(s1.id)

        #expect(store.snapshot.selection.tabID == s1.id)
        let ws = store.snapshot.workspaces.first { $0.id == store.snapshot.selection.workspaceID }
        #expect(ws?.selectedTabID == s1.id)
        // The resolved session must be the presented one.
        #expect(store.selectedSession === s1)
    }

    @Test func selectTabLeavesOtherWorkspacesSelectionAlone() {
        let a1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: a1)
        let a2 = makeSession()
        store.addTab(a2)
        let wsA = store.snapshot.selection.workspaceID

        let b1 = makeSession()
        let wsB = store.addWorkspace(initialSession: b1)

        // Select a1 back in workspace A.
        store.selectTab(a1.id)

        #expect(store.snapshot.selection.workspaceID == wsA)
        #expect(store.snapshot.workspaces.first { $0.id == wsA }?.selectedTabID == a1.id)
        // Workspace B keeps its own remembered tab.
        #expect(store.snapshot.workspaces.first { $0.id == wsB }?.selectedTabID == b1.id)
    }

    @Test func selectWorkspaceRestoresThatWorkspacesOwnTab() {
        let a1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: a1)
        let a2 = makeSession()
        store.addTab(a2)
        let wsA = store.snapshot.selection.workspaceID
        store.selectTab(a2.id)

        let b1 = makeSession()
        let wsB = store.addWorkspace(initialSession: b1)
        #expect(store.snapshot.selection.workspaceID == wsB)

        // Returning to A must land on a2, the tab last active in A.
        store.selectWorkspace(wsA)
        #expect(store.snapshot.selection.workspaceID == wsA)
        #expect(store.snapshot.selection.tabID == a2.id)
        #expect(store.selectedSession === a2)
    }

    // MARK: Removal stays in the owning workspace

    @Test func removingSelectedTabStaysInSameWorkspace() {
        let a1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: a1)

        let b1 = makeSession()
        let wsB = store.addWorkspace(initialSession: b1)
        let b2 = makeSession()
        store.addTab(b2)
        #expect(store.snapshot.selection.workspaceID == wsB)
        #expect(store.snapshot.selection.tabID == b2.id)

        // Closing the selected tab of workspace B must not teleport to A.
        _ = store.removeTab(b2.id)

        #expect(store.snapshot.selection.workspaceID == wsB)
        #expect(store.snapshot.selection.tabID == b1.id)
        #expect(store.selectedSession === b1)
    }

    // MARK: Reorder / rename / recolor

    @Test func moveTabReordersWithinWorkspace() {
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let b = makeSession()
        let c = makeSession()
        store.addTab(b)
        store.addTab(c)
        #expect(store.snapshot.workspaces[0].tabs.map(\.id) == [a.id, b.id, c.id])

        // Move the last tab to the front.
        let wsID = store.snapshot.workspaces[0].id
        store.moveTab(c.id, toWorkspace: wsID, at: 0)

        #expect(store.snapshot.workspaces[0].tabs.map(\.id) == [c.id, a.id, b.id])
        // Reordering must not change which tab is presented.
        #expect(store.snapshot.selection.tabID == c.id)
    }

    @Test func moveTabAcrossWorkspacesTransfersOwnership() {
        let a1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: a1)
        let a2 = makeSession()
        store.addTab(a2)
        let wsA = store.snapshot.workspaces[0].id

        let b1 = makeSession()
        let wsB = store.addWorkspace(initialSession: b1)

        store.moveTab(a2.id, toWorkspace: wsB, at: 0)

        let wsAAfter = store.snapshot.workspaces.first { $0.id == wsA }
        let wsBAfter = store.snapshot.workspaces.first { $0.id == wsB }
        #expect(wsAAfter?.tabs.map(\.id) == [a1.id])
        #expect(wsBAfter?.tabs.map(\.id) == [a2.id, b1.id])
        // The session object itself is unchanged — its PTY must survive.
        #expect(store.session(forTabID: a2.id) === a2)
    }

    @Test func movingTheLastTabOutOfAWorkspaceIsRefused() {
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let b = makeSession()
        let wsB = store.addWorkspace(initialSession: b)
        let wsA = store.snapshot.workspaces.first { $0.id != wsB }!.id

        // b is the only tab in wsB; moving it away would strand an empty
        // workspace, so nothing should change.
        store.moveTab(b.id, toWorkspace: wsA, at: 0)

        #expect(store.snapshot.workspaces.count == 2)
        #expect(store.snapshot.workspaces.first { $0.id == wsB }?.tabs.map(\.id) == [b.id])
    }

    @Test func moveWorkspaceReorders() {
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let wsA = store.snapshot.workspaces[0].id
        let wsB = store.addWorkspace(initialSession: makeSession())
        let wsC = store.addWorkspace(initialSession: makeSession())
        #expect(store.snapshot.workspaces.map(\.id) == [wsA, wsB, wsC])

        store.moveWorkspace(wsC, to: 0)
        #expect(store.snapshot.workspaces.map(\.id) == [wsC, wsA, wsB])
        // Reordering must not change the presented workspace.
        #expect(store.snapshot.selection.workspaceID == wsC)
    }

    @Test func renameWorkspaceUpdatesName() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id

        store.renameWorkspace(wsID, to: "  Build  ")
        #expect(store.snapshot.workspaces[0].name == "Build")

        // Whitespace-only names are ignored rather than blanking the label.
        store.renameWorkspace(wsID, to: "   ")
        #expect(store.snapshot.workspaces[0].name == "Build")
    }

    @Test func workspaceColorRoundTrips() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        #expect(store.snapshot.workspaces[0].color == .none)

        store.setWorkspaceColor(wsID, to: .teal)
        #expect(store.snapshot.workspaces[0].color == .teal)

        // A later unrelated commit must not drop the color.
        store.addTab(makeSession())
        #expect(store.snapshot.workspaces[0].color == .teal)
    }

    @Test func renameTabSetsAndClearsOverride() {
        let s = makeSession()
        let store = WorkspaceSessionStore(initialSession: s)

        store.renameTab(s.id, to: "deploy")
        #expect(s.titleOverride == "deploy")

        // An empty name clears the override so the terminal title returns.
        store.renameTab(s.id, to: "  ")
        #expect(s.titleOverride == nil)
    }

    @Test func tabColorSetsAndClears() {
        let s = makeSession()
        let store = WorkspaceSessionStore(initialSession: s)

        store.setTabColor(s.id, to: .red)
        #expect(TerminalTabColor.fromStored(s.tabColor) == .red)

        store.setTabColor(s.id, to: .none)
        #expect(s.tabColor == nil)
        #expect(TerminalTabColor.fromStored(s.tabColor) == .none)
    }

    @Test func newWorkspaceNamesDoNotDuplicateAfterAMiddleClose() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsB = store.addWorkspace(initialSession: makeSession())
        _ = store.addWorkspace(initialSession: makeSession())
        #expect(store.snapshot.workspaces.map(\.name)
                == ["Workspace 1", "Workspace 2", "Workspace 3"])

        // Closing the middle one must not make the next add reuse "Workspace 3".
        _ = store.removeWorkspace(wsB)
        _ = store.addWorkspace(initialSession: makeSession())

        let names = store.snapshot.workspaces.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.contains("Workspace 2"))
    }

    // MARK: Collapse / expand

    @Test func toggleCollapseFlipsState() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        #expect(store.snapshot.workspaces[0].isCollapsed == false)

        store.toggleWorkspaceCollapsed(wsID)
        #expect(store.snapshot.workspaces[0].isCollapsed == true)

        store.toggleWorkspaceCollapsed(wsID)
        #expect(store.snapshot.workspaces[0].isCollapsed == false)
    }

    @Test func collapseSurvivesUnrelatedCommits() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsA = store.snapshot.workspaces[0].id
        let wsB = store.addWorkspace(initialSession: makeSession())
        store.setWorkspaceCollapsed(wsA, true)

        // Adding a tab to a DIFFERENT workspace must not expand wsA.
        store.selectWorkspace(wsB)
        store.addTab(makeSession())

        #expect(store.snapshot.workspaces.first { $0.id == wsA }?.isCollapsed == true)
    }

    @Test func addingATabExpandsItsWorkspace() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceCollapsed(wsID, true)

        // A new tab that is selected but hidden would be confusing.
        store.addTab(makeSession())
        #expect(store.snapshot.workspaces[0].isCollapsed == false)
    }

    @Test func collapseOthersKeepsThePresentedWorkspaceOpen() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsA = store.snapshot.workspaces[0].id
        let wsB = store.addWorkspace(initialSession: makeSession())
        let wsC = store.addWorkspace(initialSession: makeSession())
        #expect(store.snapshot.selection.workspaceID == wsC)

        store.collapseAllExceptSelected()

        #expect(store.snapshot.workspaces.first { $0.id == wsA }?.isCollapsed == true)
        #expect(store.snapshot.workspaces.first { $0.id == wsB }?.isCollapsed == true)
        // Collapsing the presented workspace would hide the visible tab.
        #expect(store.snapshot.workspaces.first { $0.id == wsC }?.isCollapsed == false)
    }

    @Test func expandAllClearsEveryCollapse() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        _ = store.addWorkspace(initialSession: makeSession())
        store.collapseAllExceptSelected()
        #expect(store.snapshot.workspaces.contains { $0.isCollapsed })

        store.expandAll()
        #expect(store.snapshot.workspaces.allSatisfy { !$0.isCollapsed })
    }
    // MARK: F5 - defaultDirectory carry-forward matrix
    //
    // `color`/`isCollapsed` regressed once because a rebuild site used the
    // bare `WorkspaceProjection` memberwise initializer instead of carrying
    // every field forward. This matrix pins `defaultDirectory` (plus
    // `color`/`isCollapsed` alongside it) across every structural mutation
    // that rebuilds a `WorkspaceProjection`.

    @Test func defaultDirectorySurvivesRenameWorkspace() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)

        store.renameWorkspace(wsID, to: "Build")

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesSetWorkspaceColor() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")

        store.setWorkspaceColor(wsID, to: .teal)

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesSetWorkspaceCollapsed() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)

        store.setWorkspaceCollapsed(wsID, true)

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == true)
    }

    @Test func defaultDirectorySurvivesMoveTab() {
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)
        let b = makeSession()
        store.addTab(b)

        store.moveTab(b.id, toWorkspace: wsID, at: 0)

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesMoveWorkspace() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsA = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsA, to: "/tmp/x")
        store.setWorkspaceColor(wsA, to: .teal)
        let wsB = store.addWorkspace(initialSession: makeSession())
        #expect(store.snapshot.workspaces.map(\.id) == [wsA, wsB])

        store.moveWorkspace(wsA, to: 1)

        let ws = store.snapshot.workspaces.first { $0.id == wsA }
        #expect(ws?.defaultDirectory == "/tmp/x")
        #expect(ws?.color == .teal)
        #expect(ws?.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesCollapseAllExceptSelected() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsB = store.addWorkspace(initialSession: makeSession())
        store.setWorkspaceDefaultDirectory(wsB, to: "/tmp/x")
        store.setWorkspaceColor(wsB, to: .teal)
        // wsB is presented (addWorkspace selects the new workspace), so
        // select the first workspace to make wsB eligible for collapse.
        store.selectWorkspace(at: 0)

        store.collapseAllExceptSelected()

        let ws = store.snapshot.workspaces.first { $0.id == wsB }
        #expect(ws?.defaultDirectory == "/tmp/x")
        #expect(ws?.color == .teal)
        #expect(ws?.isCollapsed == true)
    }

    @Test func defaultDirectorySurvivesExpandAll() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)
        _ = store.addWorkspace(initialSession: makeSession())
        store.collapseAllExceptSelected()

        store.expandAll()

        let ws = store.snapshot.workspaces.first { $0.id == wsID }
        #expect(ws?.defaultDirectory == "/tmp/x")
        #expect(ws?.color == .teal)
        #expect(ws?.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesSelectTab() {
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)
        let b = makeSession()
        store.addTab(b)

        store.selectTab(a.id)

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesAddTab() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)

        store.addTab(makeSession())

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesRemoveTab() {
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)
        let b = makeSession()
        store.addTab(b)

        _ = store.removeTab(b.id)

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == false)
    }

    @Test func defaultDirectorySurvivesBareStageCommitRoundTrip() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp/x")
        store.setWorkspaceColor(wsID, to: .teal)
        store.setWorkspaceCollapsed(wsID, true)

        let candidate = store.stage()
        store.commit(candidate)

        let ws = store.snapshot.workspaces[0]
        #expect(ws.defaultDirectory == "/tmp/x")
        #expect(ws.color == .teal)
        #expect(ws.isCollapsed == true)
    }

    @Test func defaultDirectoryCanBeCleared() {
        let store = WorkspaceSessionStore(initialSession: makeSession())
        let wsID = store.snapshot.workspaces[0].id
        store.setWorkspaceColor(wsID, to: .teal)
        store.setWorkspaceCollapsed(wsID, true)
        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp")
        #expect(store.snapshot.workspaces[0].defaultDirectory == "/tmp")

        store.setWorkspaceDefaultDirectory(wsID, to: nil)

        // This is the entire reason `with(defaultDirectory:)` takes a
        // double-Optional. Simplifying it to a plain `String?` keeps setting
        // working and makes clearing a silent no-op, which every set-only
        // carry-forward test above would still pass.
        #expect(store.snapshot.workspaces[0].defaultDirectory == nil)
        // Clearing must not disturb the neighbouring presentation fields.
        #expect(store.snapshot.workspaces[0].color == .teal)
        #expect(store.snapshot.workspaces[0].isCollapsed == true)
    }

    private func makeSession() -> TerminalSessionState {
        TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
    }

}
// MARK: - F5 precedence
//
// `resolvedConfig` is the single point that decides a new surface's working
// directory. The rungs below are the whole feature; without these the
// stale-directory fall-through and the "workspace outranks inherited" rule are
// only verified by reading the code.

@Suite("F5 working-directory precedence")
@MainActor
struct WorkingDirectoryPrecedenceTests {
    private func workspace(defaultDirectory: String?) -> WorkspaceSession {
        WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [],
            selectedTabID: nil,
            defaultDirectory: defaultDirectory)
    }

    @Test func explicitCallerDirectoryOutranksWorkspaceDefault() {
        var base = Ghostty.SurfaceConfiguration()
        base.workingDirectory = "/explicit"

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: "/tmp"),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: base)

        // An explicit request (AppleScript initial working directory, dock
        // drop, Services) must never be silently rewritten.
        #expect(resolved?.workingDirectory == "/explicit")
    }

    @Test func workspaceDefaultAppliesWhenNoExplicitDirectory() {
        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: "/tmp"),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: nil)

        #expect(resolved?.workingDirectory == "/tmp")
    }

    @Test func workspaceDefaultPreservesOtherBaseConfigFields() {
        var base = Ghostty.SurfaceConfiguration()
        base.fontSize = 18

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: "/tmp"),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: base)

        // Rung 2 must set the directory without discarding the rest.
        #expect(resolved?.workingDirectory == "/tmp")
        #expect(resolved?.fontSize == 18)
    }

    @Test func missingDirectoryFallsThroughInsteadOfFailing() {
        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: "/nonexistent-\(UUID().uuidString)"),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: nil)

        // A deleted directory must not be applied and must not abort creation.
        #expect(resolved?.workingDirectory == nil)
    }

    @Test func fileInsteadOfDirectoryFallsThrough() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chostty-f5-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: file.path),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: nil)

        // Existing-but-not-a-directory must be rejected too, or the spawn fails.
        #expect(resolved?.workingDirectory == nil)
    }

    @Test func nilWorkspaceDefaultFallsThrough() {
        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: nil),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: nil)

        #expect(resolved?.workingDirectory == nil)
    }

    @Test func absentWorkspaceFallsThrough() {
        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: nil,
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: nil)

        #expect(resolved?.workingDirectory == nil)
    }

    @Test func inheritedDirectoryDoesNotBeatWorkspaceDefault() {
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/inherited"

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: "/tmp"),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: inherited,
            origin: .inherited)

        // libghostty populates workingDirectory purely because
        // window-inherit-working-directory is on. Treating that as an explicit
        // request would short-circuit rung 1 and silently beat the workspace
        // default — the headline F5 case.
        #expect(resolved?.workingDirectory == "/tmp")
    }

    @Test func inheritedDirectoryAppliesWhenWorkspaceHasNoDefault() {
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/inherited"

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: nil),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: inherited,
            origin: .inherited)

        // With nothing at rung 2, inheritance is still honored at rung 3.
        #expect(resolved?.workingDirectory == "/inherited")
    }

    @Test func nonDirectoryBaseConfigStillReachesRungTwo() {
        var base = Ghostty.SurfaceConfiguration()
        base.fontSize = 18

        let resolved = TerminalCommandRouter.resolvedConfig(
            workspace: workspace(defaultDirectory: "/tmp"),
            source: nil,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: base)

        // A caller supplying only a font size / command / env must not suppress
        // directory resolution; the old `baseConfig ?? inherited` collapsed the
        // four rungs into three here.
        #expect(resolved?.workingDirectory == "/tmp")
        #expect(resolved?.fontSize == 18)
    }
}

/// Tests that the reserved-shortcut matcher is keyboard-layout independent and
/// repeat-safe, which is what makes Cmd+N / Cmd+T behave identically under a
/// Korean 2-Set layout as under US QWERTY.
@MainActor
struct ReservedShortcutMatchingTests {
    private func keyEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        chars: String,
        type: NSEvent.EventType = .keyDown,
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }

    // MARK: Layout independence
    //
    // Under a Korean 2-Set layout the physical keys report Hangul jamo, not
    // Latin letters: N → "ㅜ", T → "ㅅ". A `charactersIgnoringModifiers`-based
    // matcher misses these and the event falls through to the legacy
    // native-window path, which is exactly the reported bug. Recognition must
    // depend only on the hardware key code.

    @Test func koreanLayoutCmdNRecognizedAsNewWorkspace() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: .command, chars: "ㅜ")
        #expect(router.recognize(event) == .command(.newWorkspace))
    }

    @Test func koreanLayoutCmdTRecognizedAsNewTab() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 17, flags: .command, chars: "ㅅ")
        #expect(router.recognize(event) == .command(.newTab))
    }

    @Test func koreanLayoutCmdShiftNRecognizedAsNewPhysicalWindow() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: [.command, .shift], chars: "ㅜ")
        #expect(router.recognize(event) == .command(.newPhysicalWindow))
    }

    @Test func latinAndKoreanProduceIdenticalRecognition() {
        let router = TerminalCommandRouter()
        let latin = keyEvent(keyCode: 45, flags: .command, chars: "n")
        let korean = keyEvent(keyCode: 45, flags: .command, chars: "ㅜ")
        #expect(router.recognize(latin) == router.recognize(korean))
    }

    // MARK: Command mapping

    @Test func cmdNIsNewWorkspaceNotNewWindow() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: .command, chars: "n")
        // The reported bug was Cmd+N producing a physical window.
        #expect(router.recognize(event) == .command(.newWorkspace))
        #expect(router.recognize(event) != .command(.newPhysicalWindow))
    }

    @Test func cmdTIsNewTabNotNewWindow() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 17, flags: .command, chars: "t")
        #expect(router.recognize(event) == .command(.newTab))
        #expect(router.recognize(event) != .command(.newPhysicalWindow))
    }

    @Test func cmdShiftNIsTheOnlyPhysicalWindowShortcut() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: [.command, .shift], chars: "N")
        #expect(router.recognize(event) == .command(.newPhysicalWindow))
    }

    @Test func cmdShiftTIsReopenClosedTabPerF8() {
        // Per F8/IR 2, Cmd+Shift+T was reassigned from `undo` to "Reopen
        // Closed Tab"; `undo` stays on Cmd+Z. It is now reserved, not
        // unmatched.
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 17, flags: [.command, .shift], chars: "T")
        #expect(router.recognize(event) == .command(.reopenClosedTab))
    }

    // MARK: Repeat and non-matching events

    @Test func repeatIsConsumedButNotExecuted() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: .command, chars: "n", isARepeat: true)
        // Held chord: swallowed so it cannot reach a core binding, but it must
        // not create a second workspace.
        #expect(router.recognize(event) == .consumedRepeat)
        // Still consumed at the event-monitor boundary.
        #expect(router.performReservedShortcut(event, source: nil) == true)
    }

    @Test func keyUpIsNeverReserved() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: .command, chars: "n", type: .keyUp)
        #expect(router.recognize(event) == .unmatched)
        #expect(router.performReservedShortcut(event, source: nil) == false)
    }

    @Test func extraModifiersDoNotMatch() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: [.command, .control], chars: "n")
        #expect(router.recognize(event) == .unmatched)
    }

    @Test func capsLockDoesNotBreakRouterRecognition() {
        // The router narrows to [.command,.shift,.control,.option] for the same
        // reason the dispatcher does: .deviceIndependentFlagsMask includes
        // .capsLock, so exact equality would silently kill every chord while
        // Caps Lock is engaged.
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: [.command, .capsLock], chars: "n")
        #expect(router.recognize(event) == .command(.newWorkspace))
    }

    @Test func optionModifierDoesNotMatch() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: [.command, .option], chars: "n")
        #expect(router.recognize(event) == .unmatched)
    }

    @Test func unrelatedKeycodeWithCommandDoesNotMatch() {
        let router = TerminalCommandRouter()
        // keyCode 0 == "A"
        let event = keyEvent(keyCode: 0, flags: .command, chars: "a")
        #expect(router.recognize(event) == .unmatched)
    }

    @Test func noModifierDoesNotMatch() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: [], chars: "n")
        #expect(router.recognize(event) == .unmatched)
        #expect(router.performReservedShortcut(event, source: nil) == false)
    }

    @Test func shiftAloneDoesNotMatch() {
        let router = TerminalCommandRouter()
        let event = keyEvent(keyCode: 45, flags: .shift, chars: "N")
        #expect(router.recognize(event) == .unmatched)
    }

    @Test func unmatchedEventsAreNotConsumed() {
        let router = TerminalCommandRouter()
        // An unmatched event must propagate so Ghostty core bindings still work.
        let event = keyEvent(keyCode: 0, flags: .command, chars: "a")
        #expect(router.performReservedShortcut(event, source: nil) == false)
    }
}
