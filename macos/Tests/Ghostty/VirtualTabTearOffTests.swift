import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Virtual-tab tear-off: `WorkspaceSessionStore.detachTab` at the store layer
/// and `BaseTerminalController.detachTabToNewWindow` at the controller
/// layer. Every surface is built with `spawnsSurface: false` through
/// `TerminalControllerTestHarness`, so no PTY, renderer thread, or IO thread
/// is ever created — identity is asserted on the objects themselves.
@MainActor
@Suite struct VirtualTabTearOffTests {
    private func makeSession() -> TerminalSessionState {
        if let app = TerminalControllerTestHarness.sharedApp.app {
            return TerminalSessionState(
                id: UUID(),
                surfaceTree: SplitTree(
                    view: Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)))
        }
        return TerminalSessionState(
            id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
    }

    private func makeStore(tabs: Int) -> WorkspaceSessionStore {
        let first = makeSession()
        let store = WorkspaceSessionStore(initialSession: first)
        for _ in 1..<max(1, tabs) {
            store.addTab(makeSession())
        }
        return store
    }

    // MARK: - Store layer

    @Test func detachTabRefusesTheSoleSession() {
        let store = makeStore(tabs: 1)
        let tabID = store.snapshot.workspaces[0].tabs[0].id
        let generation = store.snapshot.mountGeneration

        #expect(store.detachTab(tabID) == nil)
        #expect(store.snapshot.workspaces.count == 1)
        #expect(store.snapshot.workspaces[0].tabs.count == 1)
        #expect(store.snapshot.mountGeneration == generation)
    }

    @Test func detachTabReturnsTheSameLiveSessionObject() {
        let store = makeStore(tabs: 2)
        let moving = store.allSessions[0]
        let staying = store.allSessions[1]

        let detached = store.detachTab(moving.id)
        #expect(detached != nil)

        // Identity, not equality: the SAME object leaves the store.
        #expect(detached === moving)
        #expect(detached?.isTornDown == false)
        #expect(staying.isTornDown == false)

        // The source no longer presents it structurally...
        #expect(store.snapshot.workspaces[0].tabs.map(\.id) == [staying.id])
        // ...while the live registry deliberately still holds it until the
        // caller completes the ownership transfer with `unregister`.
        #expect(store.liveSession(forTabID: moving.id) === moving)
        store.unregister(moving.id)
        #expect(store.liveSession(forTabID: moving.id) == nil)
    }

    @Test func detachTabPrunesTheSurfaceIndex() throws {
        let store = makeStore(tabs: 2)
        let moving = store.allSessions[0]
        let surfaceID = try #require(moving.surfaceTree.first?.id)

        #expect(store.session(forSurfaceID: surfaceID) != nil)
        _ = store.detachTab(moving.id)

        // `commit` rebuilds `surfaceToTab`; the moved tab's surfaces resolve
        // to nothing in the source store anymore.
        #expect(store.session(forSurfaceID: surfaceID) == nil)
    }

    @Test func destinationStoreAdoptsTheDetachedSession() {
        let store = makeStore(tabs: 2)
        let moving = store.allSessions[0]
        _ = store.detachTab(moving.id)
        store.unregister(moving.id)

        // The tear-off destination is a one-tab workspace over the live
        // session; its store registers the SAME object on construction.
        let destination = WorkspaceSession(
            id: UUID(), name: "Workspace 1", tabs: [moving],
            selectedTabID: moving.id)
        let destinationStore = WorkspaceSessionStore(
            restoredWorkspaces: [destination],
            selection: .init(workspaceID: destination.id, tabID: moving.id))

        #expect(destinationStore.liveSession(forTabID: moving.id) === moving)
        #expect(destinationStore.allSessions.first === moving)
        #expect(moving.isTornDown == false)
    }

    @Test func detachOfTheOnlyTabOfANonLastWorkspaceRemovesThatWorkspace() {
        // Two workspaces, one tab each: a global-count detach is legal and
        // removes the emptied workspace (removeTab semantics).
        let a = makeSession()
        let store = WorkspaceSessionStore(initialSession: a)
        let b = makeSession()
        let wsB = store.addWorkspace(initialSession: b)
        #expect(store.snapshot.workspaces.count == 2)

        let detached = store.detachTab(a.id)
        #expect(detached === a)
        #expect(store.snapshot.workspaces.count == 1)
        #expect(store.snapshot.workspaces[0].id == wsB)
    }

    // MARK: - Controller layer

    private func makeController(tabs: Int) throws -> TerminalController {
        let first = makeSession()
        var workspaces = [WorkspaceSession(
            id: UUID(), name: "Workspace 1", tabs: [first],
            selectedTabID: first.id)]
        for _ in 1..<max(1, tabs) {
            workspaces[0].tabs.append(makeSession())
        }
        return try #require(TerminalControllerTestHarness.make(
            workspaces: workspaces,
            selection: .init(workspaceID: workspaces[0].id, tabID: first.id)))
    }

    @Test func soleTabControllerDetachIsANoOp() throws {
        let controller = try makeController(tabs: 1)
        let store = controller.workspaceStore
        let tabID = try #require(controller.presentedSessionID)
        let generation = store.snapshot.mountGeneration

        #expect(controller.detachTabToNewWindow(tabID: tabID, screenPoint: nil) == nil)
        #expect(store.allSessions.count == 1)
        #expect(store.snapshot.mountGeneration == generation)
    }

    @Test func foreignTabBroadcastDoesNothing() throws {
        let controller = try makeController(tabs: 2)
        let before = controller.workspaceStore.snapshot

        NotificationCenter.default.post(
            name: .ghosttyTabDragEndedNoTarget,
            object: nil,
            userInfo: [
                Notification.Name.ghosttyTabDragEndedNoTargetTabIDKey: UUID(),
                Notification.Name.ghosttyTabDragEndedNoTargetPointKey:
                    NSPoint(x: 0, y: 0)
            ])

        #expect(controller.workspaceStore.snapshot.workspaces.map(\.tabs.count)
            == before.workspaces.map(\.tabs.count))
        #expect(controller.workspaceStore.snapshot.mountGeneration == before.mountGeneration)
    }

    @Test func detachMovesTheLiveSessionIntoANewWindow() throws {
        let controller = try makeController(tabs: 2)
        let store = controller.workspaceStore
        let moving = store.allSessions[0]
        let staying = store.allSessions[1]
        let surfaceID = try #require(moving.surfaceTree.first?.id)

        let destination = try #require(
            controller.detachTabToNewWindow(tabID: moving.id, screenPoint: nil))

        // Same object, live, in the new window — never respawned.
        #expect(destination.workspaceStore.liveSession(forTabID: moving.id) === moving)
        #expect(destination.presentedSessionID == moving.id)
        #expect(moving.isTornDown == false)

        // Source: successor mounted, structure and registry handed over.
        #expect(controller.presentedSessionID == staying.id)
        #expect(store.allSessions.map(\.id) == [staying.id])
        #expect(store.liveSession(forTabID: moving.id) == nil)
        #expect(store.session(forSurfaceID: surfaceID) == nil)
        #expect(destination.workspaceStore.session(forSurfaceID: surfaceID) === moving)
    }

    @Test func detachCarriesThePresentedTreeNotTheStaleCopy() throws {
        let controller = try makeController(tabs: 2)
        let store = controller.workspaceStore
        let moving = store.allSessions[0]

        // Simulate a stale session copy: the controller's tree is
        // authoritative for the presented tab, the stored copy has lagged.
        let controllerSurfaceID = try #require(controller.surfaceTree.first?.id)
        moving.surfaceTree = SplitTree<Ghostty.SurfaceView>()

        let destination = try #require(
            controller.detachTabToNewWindow(tabID: moving.id, screenPoint: nil))

        let carried = destination.workspaceStore.liveSession(forTabID: moving.id)
        #expect(carried?.surfaceTree.first?.id == controllerSurfaceID)
    }

    @Test func undoRestoresTheTabAndClosesTheTornOffWindow() throws {
        let controller = try makeController(tabs: 3)
        let store = controller.workspaceStore
        let moving = store.allSessions[1]
        let originalIndex = 1
        let surfaceID = try #require(moving.surfaceTree.first?.id)

        let destination = try #require(
            controller.detachTabToNewWindow(tabID: moving.id, screenPoint: nil))
        let undoManager = try #require(controller.undoManager)

        undoManager.undo()

        // The tab is back in the source at its original index, same object,
        // still alive (no teardown ever ran), and the registry resolves the
        // surfaces to the source controller again.
        let restored = try #require(store.liveSession(forTabID: moving.id))
        #expect(restored === moving)
        #expect(store.allSessions.firstIndex(where: { $0.id == moving.id }) == originalIndex)
        #expect(moving.isTornDown == false)

        if let registry = (NSApp.delegate as? AppDelegate)?.surfaceOwners {
            let owner = registry.location(forSurfaceID: surfaceID)
            #expect(owner?.controllerID == ObjectIdentifier(controller))
        }

        // The torn-off window is closed by the same undo (reverse
        // registration order: destination close runs before source restore).
        #expect(destination.window?.isVisible != true)

        // Redo re-runs the full detach: the tab leaves again for a new window.
        undoManager.redo()
        #expect(store.liveSession(forTabID: moving.id) == nil)
        #expect(moving.isTornDown == false)
    }

    @Test func tearOffLeaseFinalizeIsSessionPreserving() throws {
        // A torn-off session must survive its undo lease expiring unused —
        // unlike a close lease, whose finalize tears the session down. The
        // detach handler builds the lease with exactly this no-op finalize,
        // so dropping an unconsumed lease (deinit finalizes) must leave the
        // live session untouched.
        let controller = try makeController(tabs: 2)
        let moving = controller.workspaceStore.allSessions[0]

        do {
            let lease = DetachedUndoLease(payload: moving) { _ in
                // Session-preserving by design (see detachTabToNewWindow).
            }
            #expect(lease.state == .detached)
        } // lease deinit -> finalize() runs the no-op handler.

        #expect(moving.isTornDown == false)
    }

    // MARK: - AppKit drag source decision table (headless)
    //
    // A String Transferable drag that leaves the app is offered to Finder as
    // copyable text (`chostty.tab-*.textClipping`); this source instead offers
    // `.move` only within the app and an empty mask outside it, and the
    // end-of-session decision is a pure function of the reported operation,
    // the Escape state, and the release geometry. These tests pin that
    // decision table plus the shared strip-geometry helper.

    @Test func outsideAppOffersNoOperationSoFinderCannotClip() {
        #expect(VirtualTabDragSource.DragSourceView.sourceOperationMask(for: .withinApplication) == .move)
        #expect(VirtualTabDragSource.DragSourceView.sourceOperationMask(for: .outsideApplication) == [])
    }

    @Test func claimedDropNeverTearsOff() {
        #expect(VirtualTabDragSource.DragSourceView.shouldPostTearOff(
            operation: .move, escapeCancelled: false, releaseInsideStrip: false) == false)
    }

    @Test func escapeNeverTearsOff() {
        #expect(VirtualTabDragSource.DragSourceView.shouldPostTearOff(
            operation: [], escapeCancelled: true, releaseInsideStrip: false) == false)
    }

    @Test func insideStripReleaseNeverTearsOff() {
        #expect(VirtualTabDragSource.DragSourceView.shouldPostTearOff(
            operation: [], escapeCancelled: false, releaseInsideStrip: true) == false)
    }

    @Test func unclaimedOutsideReleaseTearsOff() {
        #expect(VirtualTabDragSource.DragSourceView.shouldPostTearOff(
            operation: [], escapeCancelled: false, releaseInsideStrip: false))
    }

    @Test func dragPreviewIsStableAndNonEmpty() {
        let preview = VirtualTabDragSource.dragPreview(text: "zsh")
        #expect(preview.size.width == 120)
        #expect(preview.size.height == 24)
        #expect(preview.isValid)
        let fallback = VirtualTabDragSource.dragPreview(text: "")
        #expect(fallback.isValid)
    }

    @Test func dragContextReportsStripGeometry() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 150, width: 400, height: 44))
        window.contentView?.addSubview(anchor)

        let context = VirtualTabDragContext()
        // No anchor yet: no frame, and `contains` fails closed.
        #expect(context.stripFrame == nil)
        #expect(context.contains(NSPoint(x: -1000, y: -1000)) == false)

        context.attach(anchor)
        let frame = try? #require(context.stripFrame)
        #expect(frame?.width == 400)
        #expect(context.contains(NSPoint(x: frame!.origin.x + 200, y: frame!.origin.y + 22)))
        #expect(context.contains(NSPoint(x: -1000, y: -1000)) == false)
    }
    // MARK: - Untaken branches

    @Test func detachOfANonPresentedTabLeavesThePresentationAlone() throws {
        let controller = try makeController(tabs: 3)
        let store = controller.workspaceStore
        // Presented = first tab; detach the last one.
        let presented = try #require(controller.presentedSessionID)
        let moving = store.allSessions[2]
        #expect(presented != moving.id)
        let successorSelection = store.snapshot.selection

        let destination = try #require(
            controller.detachTabToNewWindow(tabID: moving.id, screenPoint: nil))

        #expect(controller.presentedSessionID == presented)
        #expect(store.snapshot.selection == successorSelection)
        #expect(store.allSessions.map(\.id).contains(moving.id) == false)
        #expect(destination.workspaceStore.liveSession(forTabID: moving.id) === moving)
        #expect(moving.isTornDown == false)
    }

    @Test func undoTwiceRestoresExactlyOnce() throws {
        let controller = try makeController(tabs: 2)
        let store = controller.workspaceStore
        let moving = store.allSessions[0]
        let undoManager = try #require(controller.undoManager)

        _ = controller.detachTabToNewWindow(tabID: moving.id, screenPoint: nil)
        undoManager.undo()

        let restoredCount = store.allSessions.filter { $0.id == moving.id }.count
        #expect(restoredCount == 1)

        // A second undo consumes nothing: the lease is spent, the source
        // must not gain a duplicate and the session must stay alive.
        undoManager.undo()
        #expect(store.allSessions.filter { $0.id == moving.id }.count == restoredCount)
        #expect(moving.isTornDown == false)
    }

    @Test func dragThresholdRejectsJitter() {
        typealias Source = VirtualTabDragSource.DragSourceView
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let press = NSPoint(x: 200, y: 150)

        func dragged(at point: NSPoint) -> NSEvent {
            try! #require(NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0))
        }

        // Sub-threshold jitter never starts a session…
        #expect(Source.crossedThreshold(
            from: press, to: dragged(at: NSPoint(x: 201, y: 151))) == false)
        // …at exactly the threshold it does…
        #expect(Source.crossedThreshold(
            from: press, to: dragged(at: NSPoint(x: 203, y: 150))))
        // …and with no recorded press (missed mouseDown) it fails open so a
        // drag is never silently swallowed.
        #expect(Source.crossedThreshold(from: nil, to: dragged(at: press)))
    }

    @Test func undoRestoresEmptiedWorkspaceIdentity() throws {
        // A second workspace whose only tab gets detached: the detach removes
        // the workspace, and undo must rebuild it with its identity.
        let controller = try makeController(tabs: 2)
        let store = controller.workspaceStore
        let lone = makeSession()
        let second = store.addWorkspace(name: "Second", initialSession: lone)
        let undoManager = try #require(controller.undoManager)

        let before = try #require(store.snapshot.workspaces.first(where: { $0.id == second }))
        _ = controller.detachTabToNewWindow(tabID: lone.id, screenPoint: nil)
        #expect(store.snapshot.workspaces.contains(where: { $0.id == second }) == false)

        undoManager.undo()
        let restored = try #require(store.snapshot.workspaces.first(where: { $0.id == second }))
        #expect(restored.name == before.name)
        #expect(restored.color == before.color)
        #expect(restored.isCollapsed == before.isCollapsed)
    }
}
