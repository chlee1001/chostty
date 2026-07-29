import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Tests for the destructive-close ownership contract.
///
/// A `DetachedUndoLease` exclusively owns resources that have been removed from
/// every live store/registry. It has three states — `detached`, `consumed`, and
/// `finalized`:
///
/// - `consume()` transfers the payload exactly once (undo path).
/// - `finalize()` idempotently tears the payload down exactly once (expiry path).
/// - Consuming after finalizing, or finalizing after consuming, must never
///   double-tear-down or resurrect a payload.
struct DetachedUndoLeaseTests {
    /// A trivial reference payload we can observe teardown on.
    final class Payload {
        var tornDown = 0
    }

    @Test func startsDetachedAndOwnsPayload() {
        let p = Payload()
        let lease = DetachedUndoLease(payload: p) { $0.tornDown += 1 }
        #expect(lease.state == .detached)
        #expect(lease.payload === p)
        #expect(p.tornDown == 0)
    }

    @Test func consumeTransfersPayloadExactlyOnce() {
        let p = Payload()
        let lease = DetachedUndoLease(payload: p) { $0.tornDown += 1 }

        let first = lease.consume()
        #expect(first === p)
        #expect(lease.state == .consumed)
        #expect(lease.payload == nil)

        // Second consume yields nothing — the payload moved out.
        let second = lease.consume()
        #expect(second == nil)
    }

    @Test func consumeDoesNotTearDown() {
        let p = Payload()
        let lease = DetachedUndoLease(payload: p) { $0.tornDown += 1 }
        _ = lease.consume()
        // Undo took ownership; the resource must stay alive.
        #expect(p.tornDown == 0)
    }

    @Test func finalizeTearsDownExactlyOnce() {
        let p = Payload()
        let lease = DetachedUndoLease(payload: p) { $0.tornDown += 1 }

        lease.finalize()
        #expect(lease.state == .finalized)
        #expect(p.tornDown == 1)

        // Idempotent: repeated finalize must not tear down again.
        lease.finalize()
        lease.finalize()
        #expect(p.tornDown == 1)
    }

    @Test func finalizeAfterConsumeDoesNotTearDown() {
        let p = Payload()
        let lease = DetachedUndoLease(payload: p) { $0.tornDown += 1 }

        _ = lease.consume()
        lease.finalize()

        // The payload was handed to undo, so the lease owns nothing to destroy.
        #expect(p.tornDown == 0)
        #expect(lease.state == .finalized)
    }

    @Test func consumeAfterFinalizeReturnsNil() {
        let p = Payload()
        let lease = DetachedUndoLease(payload: p) { $0.tornDown += 1 }

        lease.finalize()
        #expect(lease.consume() == nil)
        // Still exactly one teardown.
        #expect(p.tornDown == 1)
    }

    @Test func arrayPayloadTearsDownEveryElementOnce() {
        let a = Payload()
        let b = Payload()
        let lease = DetachedUndoLease(payload: [a, b]) { payloads in
            for p in payloads { p.tornDown += 1 }
        }

        lease.finalize()
        #expect(a.tornDown == 1)
        #expect(b.tornDown == 1)

        lease.finalize()
        #expect(a.tornDown == 1)
        #expect(b.tornDown == 1)
    }

    @Test func arrayPayloadConsumeKeepsAllAlive() {
        let a = Payload()
        let b = Payload()
        let lease = DetachedUndoLease(payload: [a, b]) { payloads in
            for p in payloads { p.tornDown += 1 }
        }

        let restored = lease.consume()
        #expect(restored?.count == 2)
        #expect(a.tornDown == 0)
        #expect(b.tornDown == 0)
    }
}

/// Tests that store-level undo re-insertion restores position and identity.
@MainActor
struct WorkspaceUndoReinsertionTests {
    private func makeSession() -> TerminalSessionState {
        TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
    }

    @Test func insertTabRestoresOriginalIndex() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = makeSession()
        let s3 = makeSession()
        store.addTab(s2)
        store.addTab(s3)

        let wsID = store.snapshot.workspaces[0].id
        // Order is now [s1, s2, s3]; remove the middle one.
        let removed = store.removeTab(s2.id)
        #expect(removed != nil)
        #expect(store.snapshot.workspaces[0].tabs.map(\.id) == [s1.id, s3.id])

        // Undo puts it back at index 1.
        store.insertTab(s2, intoWorkspace: wsID, at: 1)
        #expect(store.snapshot.workspaces[0].tabs.map(\.id) == [s1.id, s2.id, s3.id])
        #expect(store.snapshot.selection.tabID == s2.id)
    }

    @Test func insertTabClampsOutOfRangeIndex() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let wsID = store.snapshot.workspaces[0].id
        let s2 = makeSession()

        // Index far beyond the end must clamp to append, not crash.
        store.insertTab(s2, intoWorkspace: wsID, at: 999)
        #expect(store.snapshot.workspaces[0].tabs.count == 2)
        #expect(store.snapshot.workspaces[0].tabs.last?.id == s2.id)
    }

    @Test func insertWorkspaceRestoresIdentityOrderAndSelection() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)

        let a = makeSession()
        let b = makeSession()
        let wsID = store.addWorkspace(initialSession: a)
        store.addTab(b, toWorkspace: wsID)

        #expect(store.snapshot.workspaces.count == 2)
        let removedIndex = store.snapshot.workspaces.firstIndex(where: { $0.id == wsID })
        let removedName = store.snapshot.workspaces[removedIndex!].name

        let removedSessions = store.removeWorkspace(wsID)
        #expect(removedSessions.count == 2)
        #expect(store.snapshot.workspaces.count == 1)

        // Undo restores the same workspace UUID, name, order, and selection.
        store.insertWorkspace(
            id: wsID,
            name: removedName,
            sessions: removedSessions,
            selectedTabID: b.id,
            at: removedIndex,
            defaultDirectory: nil,
            color: .none,
            isCollapsed: false)

        #expect(store.snapshot.workspaces.count == 2)
        let restored = store.snapshot.workspaces.first(where: { $0.id == wsID })
        #expect(restored != nil)
        #expect(restored?.name == removedName)
        #expect(restored?.tabs.map(\.id) == [a.id, b.id])
        #expect(store.snapshot.selection.workspaceID == wsID)
        #expect(store.snapshot.selection.tabID == b.id)
    }

    @Test func insertTabIntoMissingWorkspaceCreatesNewWorkspace() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let orphan = makeSession()

        // The target workspace never existed — the session must not be dropped.
        store.insertTab(orphan, intoWorkspace: UUID(), at: 0)
        #expect(store.session(forTabID: orphan.id) != nil)
        #expect(store.allSessions.contains { $0.id == orphan.id })
    }

    // MARK: Restored workspaces keep their presentation state
    //
    // `insertWorkspace` is only ever called by `closeWorkspace`'s undo handler,
    // so it always restores a workspace that ALREADY existed. Building its
    // projection with the bare memberwise initializer reset defaultDirectory,
    // color and isCollapsed to their defaults, which meant Close Workspace
    // followed by Cmd+Z silently discarded those user choices.

    @Test func insertWorkspaceRestoresDefaultDirectoryColorAndCollapse() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = makeSession()
        let wsID = store.addWorkspace(initialSession: s2)

        store.setWorkspaceDefaultDirectory(wsID, to: "/tmp")
        store.setWorkspaceColor(wsID, to: .teal)
        store.setWorkspaceCollapsed(wsID, true)

        let before = store.snapshot.workspaces.first { $0.id == wsID }
        #expect(before?.defaultDirectory == "/tmp")
        #expect(before?.color == .teal)
        #expect(before?.isCollapsed == true)

        let index = store.snapshot.workspaces.firstIndex { $0.id == wsID }
        let sessions = store.removeWorkspace(wsID)
        #expect(!sessions.isEmpty)

        // Restore exactly as closeWorkspace's undo handler does.
        for session in sessions { store.register(session) }
        store.insertWorkspace(
            id: wsID,
            name: before!.name,
            sessions: sessions,
            selectedTabID: before!.selectedTabID,
            at: index,
            defaultDirectory: before!.defaultDirectory,
            color: before!.color,
            isCollapsed: before!.isCollapsed)

        let after = store.snapshot.workspaces.first { $0.id == wsID }
        #expect(after?.defaultDirectory == "/tmp")
        #expect(after?.color == .teal)
        #expect(after?.isCollapsed == true)
        // And it lands back in its original position.
        #expect(store.snapshot.workspaces.firstIndex { $0.id == wsID } == index)
    }

    // MARK: Last-tab / last-workspace refusal
    //
    // A controller must always own at least one workspace with at least one
    // tab. Removing the final tab would leave an empty hierarchy with a
    // dangling selection, so the store refuses it rather than committing an
    // invalid snapshot.

    @Test func removingTheOnlyTabIsRefused() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)

        let removed = store.removeTab(s1.id)

        #expect(removed == nil)
        #expect(store.snapshot.workspaces.count == 1)
        #expect(store.snapshot.workspaces[0].tabs.count == 1)
        #expect(store.snapshot.selection.tabID == s1.id)
        #expect(store.session(forTabID: s1.id) != nil)
    }

    @Test func removingTheOnlyWorkspaceIsRefused() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let wsID = store.snapshot.workspaces[0].id

        let removed = store.removeWorkspace(wsID)

        #expect(removed.isEmpty)
        #expect(store.snapshot.workspaces.count == 1)
        #expect(store.snapshot.selection.workspaceID == wsID)
    }

    @Test func removingLastTabOfNonLastWorkspaceRemovesThatWorkspace() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = makeSession()
        let wsID = store.addWorkspace(initialSession: s2)

        #expect(store.snapshot.workspaces.count == 2)

        // s2 is the only tab in its workspace, but another workspace exists, so
        // this removal is legal and collapses the now-empty workspace.
        let removed = store.removeTab(s2.id)

        #expect(removed != nil)
        #expect(store.snapshot.workspaces.count == 1)
        #expect(!store.snapshot.workspaces.contains { $0.id == wsID })
        // Selection must land on a live tab.
        #expect(store.session(forTabID: store.snapshot.selection.tabID) != nil)
    }

    @Test func selectionAlwaysReferencesALiveTabAfterRemovals() {
        let s1 = makeSession()
        let store = WorkspaceSessionStore(initialSession: s1)
        let s2 = makeSession()
        let s3 = makeSession()
        store.addTab(s2)
        store.addTab(s3)

        _ = store.removeTab(s3.id)
        #expect(store.session(forTabID: store.snapshot.selection.tabID) != nil)

        _ = store.removeTab(s2.id)
        #expect(store.session(forTabID: store.snapshot.selection.tabID) != nil)

        // Only s1 remains; further removal is refused.
        #expect(store.removeTab(s1.id) == nil)
        #expect(store.session(forTabID: store.snapshot.selection.tabID) != nil)
    }
}
