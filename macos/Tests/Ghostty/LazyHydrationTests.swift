import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Lazy hydration, the partial-hydration invariants, and the second-instance
/// ownership decision. Every hydration path receives an injected constructor
/// that builds `spawnsSurface: false` views, so no PTY is created in the test
/// host.
@MainActor
@Suite struct LazyHydrationTests {
    // MARK: - Fixtures

    private func makeLeaf(cwd: String? = nil) -> PaneLeafSnapshot {
        PaneLeafSnapshot(uuid: UUID(), cwd: cwd, title: nil)
    }

    private func makeTab(id: UUID = UUID(), panes: Int = 1, cwd: String? = nil) -> TabSnapshot {
        var tree: PaneTreeSnapshot = .leaf(makeLeaf(cwd: cwd))
        for _ in 1..<max(panes, 1) {
            tree = .split(
                direction: .horizontal,
                ratio: 0.5,
                left: tree,
                right: .leaf(makeLeaf(cwd: cwd))
            )
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

    private func inertConstructor() -> TerminalControllerGraphFactory.SurfaceConstructor {
        { config, uuid in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }
    }

    /// A controller whose second tab is pending hydration, as boot leaves it.
    private func makeControllerWithPendingTab(
        pendingPanes: Int = 2,
        pendingCwd: String? = nil,
        pendingSnapshot: TabSnapshot? = nil,
        construct: TerminalControllerGraphFactory.SurfaceConstructor? = nil
    ) throws -> (TerminalController, PendingHydrationRegistry, TerminalSessionState) {
        let liveView = try #require(inertSurface())
        let live = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: liveView))
        live.focusedSurfaceID = liveView.id

        let pendingID = pendingSnapshot?.id ?? UUID()
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
        registry.store(
            pendingSnapshot ?? makeTab(id: pendingID, panes: pendingPanes, cwd: pendingCwd),
            for: pendingID
        )
        controller.injectRestoreBindings(.init(registry: registry, construct: construct ?? inertConstructor()))

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

    @Test func aLiveTreeWinsOverAStalePendingEntry() throws {
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingPanes: 2)

        // Something gave the tab a live tree before it was selected.
        let existing = try #require(inertSurface())
        pending.surfaceTree = SplitTree(view: existing)

        let outcome = controller.hydratePendingSession(pending)

        #expect(Array(pending.surfaceTree).map(\.id) == [existing.id])
        #expect(registry.isEmpty)
        #expect(outcome == .alreadyLive)
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

    @Test func hydratedPaneKeepsItsRecordedCwdBeforeTheShellReports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-hydrated-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, _, pending) = try makeControllerWithPendingTab(pendingCwd: directory.path)

        controller.selectSession(workspaceID: try workspaceID(of: controller), tabID: pending.id)

        #expect(pending.surfaceTree.first?.pwd == directory.path)
    }

    @Test func hydrationDoesNotBlankTheSidebarPwd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-sidebar-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, _, pending) = try makeControllerWithPendingTab(pendingCwd: directory.path)

        controller.selectSession(workspaceID: try workspaceID(of: controller), tabID: pending.id)

        #expect(pending.pwd == directory.path)
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
        controller.injectRestoreBindings(.init(registry: registry, construct: inertConstructor()))

        controller.selectSession(workspaceID: workspace.id, tabID: newID)

        #expect(Array(reopened.surfaceTree).count == 2)
        #expect(registry.isEmpty)
    }

    @Test func aPartiallyFailedHydrationKeepsTheWholeStoredTree() throws {
        // Real directories: a recorded cwd that no longer exists is dropped on
        // restore, which would make the rebuilt tree differ from the stored one.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func liveDirectory(_ name: String) throws -> String {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        let first = makeLeaf(cwd: try liveDirectory("first"))
        let focused = makeLeaf(cwd: try liveDirectory("focused"))
        let failed = makeLeaf(cwd: try liveDirectory("failed"))
        let tree = PaneTreeSnapshot.split(
            direction: .horizontal,
            ratio: 0.6,
            left: .leaf(first),
            right: .split(
                direction: .vertical,
                ratio: 0.25,
                left: .leaf(focused),
                right: .leaf(failed)
            )
        )
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: tree,
            focusedPaneID: focused.uuid,
            zoomedPaneID: focused.uuid
        )
        let failingConstructor: TerminalControllerGraphFactory.SurfaceConstructor = { _, uuid in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: uuid, spawnsSurface: false)
            if uuid == failed.uuid {
                view.error = Ghostty.Error.apiFailed
            }
            return view
        }
        let (controller, registry, pending) = try makeControllerWithPendingTab(
            pendingSnapshot: tab,
            construct: failingConstructor
        )
        let workspace = try #require(controller.workspaceStore.snapshot.workspaces.first)
        let expected = SessionSnapshotProjection.workspace(from: workspace, pendingTabs: registry.allPending)

        #expect(controller.hydratePendingSession(pending) == .failed)
        #expect(pending.surfaceTree.isEmpty)
        #expect(registry.snapshot(for: pending.id) == tab)
        for _ in 0..<3 {
            #expect(SessionSnapshotProjection.workspace(from: workspace, pendingTabs: registry.allPending) == expected)
        }

        controller.injectRestoreBindings(.init(registry: registry, construct: inertConstructor()))
        controller.selectSession(workspaceID: workspace.id, tabID: pending.id)

        #expect(SessionSnapshotProjection.paneTree(from: pending.surfaceTree) == tree)
        #expect(SessionSnapshotProjection.zoomedPaneID(in: pending.surfaceTree) == focused.uuid)
        #expect(pending.focusedSurfaceID == focused.uuid)
    }

    @Test func failedHydrationReleasesTheViewsItBuilt() throws {
        let tab = makeTab(panes: 2)
        let failedID = try #require(tab.paneTree?.leaves.last?.uuid)
        weak var builtView: Ghostty.SurfaceView?
        let constructor: TerminalControllerGraphFactory.SurfaceConstructor = { _, uuid in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: uuid, spawnsSurface: false)
            if uuid == failedID {
                view.error = Ghostty.Error.apiFailed
            } else {
                builtView = view
            }
            return view
        }
        let (controller, _, pending) = try makeControllerWithPendingTab(
            pendingSnapshot: tab,
            construct: constructor
        )

        let outcome = autoreleasepool { controller.hydratePendingSession(pending) }
        #expect(outcome == .failed)
        #expect(builtView == nil)
    }

    @Test func aFailedPresentedTabRetriesWhenItIsSelectedAgain() throws {
        let tab = makeTab(panes: 2)
        let failedID = try #require(tab.paneTree?.leaves.last?.uuid)
        let failingConstructor: TerminalControllerGraphFactory.SurfaceConstructor = { _, uuid in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: uuid, spawnsSurface: false)
            if uuid == failedID {
                view.error = Ghostty.Error.apiFailed
            }
            return view
        }
        let (controller, registry, pending) = try makeControllerWithPendingTab(
            pendingSnapshot: tab,
            construct: failingConstructor
        )
        let workspaceID = try workspaceID(of: controller)

        controller.selectSession(workspaceID: workspaceID, tabID: pending.id)
        let generation = controller.workspaceStore.snapshot.mountGeneration
        #expect(controller.presentedSessionID == pending.id)
        #expect(controller.surfaceTree.isEmpty)
        #expect(registry.contains(pending.id))

        controller.injectRestoreBindings(.init(registry: registry, construct: inertConstructor()))
        controller.selectSession(workspaceID: workspaceID, tabID: pending.id)

        #expect(controller.workspaceStore.snapshot.mountGeneration == generation)
        #expect(Array(controller.surfaceTree).count == 2)
        #expect(controller.presentedSessionID == pending.id)
    }

    @Test func detachingAPendingTabHydratesItBeforeTheNewWindowPresentsIt() throws {
        let (controller, _, pending) = try makeControllerWithPendingTab(pendingPanes: 3)

        let destination = try #require(
            controller.detachTabToNewWindow(tabID: pending.id, screenPoint: nil)
        )

        #expect(Array(destination.surfaceTree).count == 3)
        #expect(destination.presentedSessionID == pending.id)
    }

    @Test func aStoredTabWithoutPanesHydratesAsOneFreshPane() throws {
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: nil,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let (controller, registry, pending) = try makeControllerWithPendingTab(pendingSnapshot: tab)

        controller.selectSession(workspaceID: try workspaceID(of: controller), tabID: pending.id)

        #expect(Array(pending.surfaceTree).count == 1)
        #expect(!registry.contains(pending.id))
    }

    // MARK: - Second-instance ownership

    private func makePersistence(
        ownerInstanceID: UUID = UUID(),
        directory: URL? = nil,
        isLiveInstance: @escaping (Int32) -> Bool = { _ in false }
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
            isLiveInstance: isLiveInstance,
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
        let persistence = try makePersistence { _ in false }
        let previousRun = storedSnapshot(ownerInstanceID: UUID(), ownerPID: 999_999)

        let isSecond = persistence.adoptOwnership(of: previousRun)

        #expect(!isSecond)
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func aLiveForeignOwnerMakesThisInstancePassive() throws {
        let persistence = try makePersistence { pid in pid == 12_345 }
        let otherApp = storedSnapshot(ownerInstanceID: UUID(), ownerPID: 12_345)

        let isSecond = persistence.adoptOwnership(of: otherApp)

        #expect(isSecond)
        #expect(persistence.isDisabledBySecondInstance)
        #expect(persistence.foreignOwnerPID == 12_345)
    }

    @Test func firstEverLaunchHasNoOwnerToDeferTo() throws {
        let persistence = try makePersistence { _ in true }
        #expect(!persistence.adoptOwnership(of: nil))
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func ourOwnFileIsNeverTreatedAsForeign() throws {
        let ownerInstanceID = UUID()
        let persistence = try makePersistence(ownerInstanceID: ownerInstanceID) { _ in true }
        let ours = storedSnapshot(ownerInstanceID: ownerInstanceID, ownerPID: 4242)

        // Alive pid, but it is us.
        #expect(!persistence.adoptOwnership(of: ours))
        #expect(!persistence.isDisabledBySecondInstance)
    }

    @Test func unownedRecoveredFieldsDoNotClaimOwnership() throws {
        let persistence = try makePersistence(isLiveInstance: SessionPersistenceController.isLiveAppInstance)
        let recovered = storedSnapshot(
            ownerInstanceID: AppSessionSnapshot.unownedInstanceID,
            ownerPID: AppSessionSnapshot.unownedPID
        )

        // pid 0 is never alive, so corrupt owner bookkeeping reads as unowned
        // and this process keeps saving.
        #expect(!persistence.adoptOwnership(of: recovered))
        #expect(!persistence.isDisabledBySecondInstance)
    }

}
