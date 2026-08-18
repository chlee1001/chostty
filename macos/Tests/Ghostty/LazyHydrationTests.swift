import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Lazy hydration, the partial-hydration invariants, and the second-instance
/// ownership decision. No real terminal is created: hydration builds its panes
/// with `spawnsSurface: false` views, so the path can be asserted without
/// accumulating PTYs in the test host.
@MainActor
@Suite struct LazyHydrationTests {
    // MARK: - Fixtures

    private func makeLeaf(cwd: String? = nil) -> PaneLeafSnapshot {
        PaneLeafSnapshot(uuid: UUID(), cwd: cwd, title: nil)
    }

    private func makeTab(id: UUID = UUID(), panes: Int = 1) -> TabSnapshot {
        var tree: PaneTreeSnapshot = .leaf(makeLeaf())
        for _ in 1..<max(panes, 1) {
            tree = .split(direction: .horizontal, ratio: 0.5, left: tree, right: .leaf(makeLeaf()))
        }
        return TabSnapshot(
            id: id,
            titleOverride: nil,
            tabColor: nil,
            paneTree: tree,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
    }

    private func inertSurface() -> Ghostty.SurfaceView? {
        guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
        return Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
    }

    /// A controller whose second tab is pending hydration, as boot leaves it.
    private func makeControllerWithPendingTab(
        pendingPanes: Int = 2
    ) throws -> (TerminalController, PendingHydrationRegistry, TerminalSessionState) {
        let liveView = try #require(inertSurface())
        let live = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: liveView))
        live.focusedSurfaceID = liveView.id

        let pendingID = UUID()
        let pending = TerminalSessionState(id: pendingID, surfaceTree: SplitTree<Ghostty.SurfaceView>())

        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Workspace 1",
            tabs: [live, pending],
            selectedTabID: live.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: live.id)
        ))

        let registry = PendingHydrationRegistry()
        registry.store(makeTab(id: pendingID, panes: pendingPanes), for: pendingID)
        controller.pendingHydrationOverride = registry

        return (controller, registry, pending)
    }

    private func workspaceID(of controller: TerminalController) throws -> UUID {
        try #require(controller.workspaceStore.snapshot.workspaces.first?.id)
    }

    // MARK: - Hydration on first selection

    @Test func selectingAPendingTabMaterializesItsPanes() throws {
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingPanes: 3)
        #expect(pending.surfaceTree.isEmpty)

        controller.selectSession(workspaceID: try workspaceID(of: controller), tabID: pending.id)

        #expect(Array(pending.surfaceTree).count == 3)
        #expect(!registry.contains(pending.id))
        #expect(registry.isEmpty)
        #expect(controller.presentedSessionID == pending.id)
        #expect(Array(controller.surfaceTree).count == 3)
    }

    /// Why the hook's placement is load-bearing:
    /// `ReservedShortcutDispatcher.select(workspace:on:)` commits the selection
    /// through `selectWorkspace` BEFORE calling `selectSession`, so a hook
    /// inside the selection-commit block never runs for the workspace-switch
    /// shortcuts and they mount an empty tab.
    @Test func hydrationRunsEvenWhenTheSelectionIsAlreadyCommitted() throws {
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingPanes: 2)
        let store = controller.workspaceStore
        let wsID = try workspaceID(of: controller)

        // Commit first, exactly like the workspace-switch path.
        let candidate = store.candidateSelecting(workspaceID: wsID, tabID: pending.id)
        #expect(store.validate(candidate))
        store.commit(candidate)
        #expect(store.snapshot.selection == Selection(workspaceID: wsID, tabID: pending.id))

        controller.selectSession(workspaceID: wsID, tabID: pending.id)

        #expect(Array(pending.surfaceTree).count == 2)
        #expect(!registry.contains(pending.id))
    }

    @Test func hydrationIsIdempotent() throws {
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingPanes: 2)
        let wsID = try workspaceID(of: controller)
        let liveID = try #require(controller.presentedSessionID)

        controller.selectSession(workspaceID: wsID, tabID: pending.id)
        let firstPaneIDs = Set(pending.surfaceTree.map(\.id))

        controller.selectSession(workspaceID: wsID, tabID: liveID)
        controller.selectSession(workspaceID: wsID, tabID: pending.id)

        #expect(Set(pending.surfaceTree.map(\.id)) == firstPaneIDs)
        #expect(registry.isEmpty)
    }

    @Test func aSessionThatIsAlreadyLiveIsNotOverwritten() throws {
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingPanes: 2)

        // Something gave the tab a live tree before it was selected.
        let existing = try #require(inertSurface())
        pending.surfaceTree = SplitTree(view: existing)

        controller.selectSession(workspaceID: try workspaceID(of: controller), tabID: pending.id)

        #expect(Array(pending.surfaceTree).map(\.id) == [existing.id])
        #expect(registry.isEmpty)
    }

    @Test func hydratedPanesAreResolvableThroughTheOwnerRegistry() throws {
        let (controller, _, pending) = try makeControllerWithPendingTab(pendingPanes: 2)
        controller.selectSession(workspaceID: try workspaceID(of: controller), tabID: pending.id)

        // New objects: without the owner index, source lookup, command palette
        // focus and AppleScript addressing all miss.
        for pane in pending.surfaceTree {
            #expect(controller.workspaceStore.tabID(forSurfaceID: pane.id) == pending.id)
        }
    }

    // MARK: - Partial-hydration invariants

    @Test func closingAndReopeningAPendingTabKeepsItsPaneCount() throws {
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingPanes: 3)
        let wsID = try workspaceID(of: controller)

        controller.closeWorkspaceTab(pending.id)
        controller.reopenClosedTab()

        // Whichever path reopen took, the tab must still describe three panes.
        let restored = try #require(
            controller.workspaceStore.snapshot.workspaces
                .first { $0.id == wsID }?
                .tabs.last
        )
        let pendingPaneCount = registry.snapshot(for: restored.id)?.paneTree?.paneCount
        let livePaneCount = Array(restored.surfaceTree).count
        #expect((pendingPaneCount ?? livePaneCount) == 3)
    }

    @Test func rekeyedPendingTabHydratesUnderItsNewIdentity() throws {
        let registry = PendingHydrationRegistry()
        let oldID = UUID()
        let newID = UUID()
        registry.store(makeTab(id: oldID, panes: 2), for: oldID)
        registry.rekey(from: oldID, to: newID)

        let liveView = try #require(inertSurface())
        let live = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: liveView))
        let reopened = TerminalSessionState(id: newID, surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [live, reopened],
            selectedTabID: live.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: live.id)
        ))
        controller.pendingHydrationOverride = registry

        controller.selectSession(workspaceID: workspace.id, tabID: newID)

        #expect(Array(reopened.surfaceTree).count == 2)
        #expect(registry.isEmpty)
    }

    // MARK: - Second-instance ownership

    private func makePersistence(
        ownerInstanceID: UUID = UUID(),
        directory: URL? = nil
    ) throws -> SessionPersistenceController {
        let directory = try directory ?? {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("chostty-owner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }()
        return SessionPersistenceController(
            repository: SessionSnapshotRepository(directory: directory),
            gate: SessionPersistenceGate(environment: [:], arguments: [], configEnabled: true),
            registry: PendingHydrationRegistry(),
            ownerInstanceID: ownerInstanceID,
            ownerPID: 4242,
            controllersProvider: { [] }
        )
    }

    private func storedSnapshot(ownerInstanceID: UUID, ownerPID: Int32) -> AppSessionSnapshot {
        AppSessionSnapshot(ownerInstanceID: ownerInstanceID, ownerPID: ownerPID, windows: [])
    }

    /// The ordinary relaunch. A different instance id is guaranteed and the
    /// previous run always saved on quit, so a predicate that stopped at the id
    /// mismatch would disable saving from the second launch onward.
    @Test func ordinaryRelaunchKeepsSavingWhenThePreviousOwnerIsGone() throws {
        let persistence = try makePersistence()
        let previousRun = storedSnapshot(ownerInstanceID: UUID(), ownerPID: 999_999)

        let isSecond = persistence.adoptOwnership(of: previousRun) { _ in false }

        #expect(!isSecond)
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func aLiveForeignOwnerMakesThisInstancePassive() throws {
        let persistence = try makePersistence()
        let otherApp = storedSnapshot(ownerInstanceID: UUID(), ownerPID: 12_345)

        let isSecond = persistence.adoptOwnership(of: otherApp) { pid in pid == 12_345 }

        #expect(isSecond)
        #expect(persistence.isDisabledBySecondInstance)
    }

    @Test func firstEverLaunchHasNoOwnerToDeferTo() throws {
        let persistence = try makePersistence()
        #expect(!persistence.adoptOwnership(of: nil) { _ in true })
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func ourOwnFileIsNeverTreatedAsForeign() throws {
        let ownerInstanceID = UUID()
        let persistence = try makePersistence(ownerInstanceID: ownerInstanceID)
        let ours = storedSnapshot(ownerInstanceID: ownerInstanceID, ownerPID: 4242)

        // Alive pid, but it is us.
        #expect(!persistence.adoptOwnership(of: ours) { _ in true })
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func unownedRecoveredFieldsDoNotClaimOwnership() throws {
        let persistence = try makePersistence()
        let recovered = storedSnapshot(
            ownerInstanceID: AppSessionSnapshot.unownedInstanceID,
            ownerPID: AppSessionSnapshot.unownedPID
        )

        // pid 0 is never alive, so corrupt owner bookkeeping reads as unowned
        // and this process keeps saving.
        #expect(!persistence.adoptOwnership(of: recovered))
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func livenessTreatsOnlyNoSuchProcessAsDead() {
        // launchd always exists; a non-positive pid never does.
        #expect(SessionPersistenceController.processIsAlive(1))
        #expect(!SessionPersistenceController.processIsAlive(0))
        #expect(!SessionPersistenceController.processIsAlive(-1))
        // Ourselves, by definition.
        #expect(SessionPersistenceController.processIsAlive(Int32(ProcessInfo.processInfo.processIdentifier)))
    }
}
