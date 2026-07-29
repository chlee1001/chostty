import Foundation
import Testing
@testable import Ghostty

/// Tests for `ClosedTabHistory`, the SOLE authority for F8 "Reopen Closed Tab"
/// (Cmd+Shift+T). These exercise the ring/eviction/fast-path/fallback
/// mechanism directly, independent of the shared, process-wide `undoManager`
/// stack (which is what a blind `undoManager.undo()` would incorrectly pop —
/// see `BaseTerminalController.reopenClosedTab()`'s doc).
struct ClosedTabHistoryTests {
    private func makeSession() -> TerminalSessionState {
        TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
    }

    private func record(
        workspaceID: UUID = UUID(),
        index: Int? = 0,
        pwd: String? = "/tmp",
        titleOverride: String? = nil,
        tabColor: TerminalTabColor = .none
    ) -> ClosedTabHistory.Record {
        ClosedTabHistory.Record(
            workspaceID: workspaceID,
            workspaceName: "Workspace 1",
            index: index,
            title: "title",
            titleOverride: titleOverride,
            pwd: pwd,
            tabColor: tabColor)
    }

    // MARK: - Recency

    @Test func popNewestReturnsTheMostRecentlyRecordedEntry() throws {
        let history = ClosedTabHistory()
        let s1 = makeSession()
        let s2 = makeSession()
        // History now holds leases WEAKLY (see `SingleLeaseGroup`'s doc) —
        // the sole strong owner in production is the undo registration
        // closure. Here that owner is these locals, kept alive for the
        // duration of the test.
        let lease1 = DetachedUndoLease(payload: s1) { $0.tearDown() }
        let lease2 = DetachedUndoLease(payload: s2) { $0.tearDown() }
        history.recordSingle(record(), lease: lease1)
        history.recordSingle(record(), lease: lease2)

        let popped = try #require(history.popNewest())
        let sessions = try #require(popped.leaseGroup.consumeAll())
        #expect(sessions.first === s2)
    }

    @Test func poppingConsumesTheEntryOnlyOnce() {
        let history = ClosedTabHistory()
        let s1 = makeSession()
        let lease1 = DetachedUndoLease(payload: s1) { $0.tearDown() }
        history.recordSingle(record(), lease: lease1)

        #expect(history.count == 1)
        #expect(history.popNewest() != nil)
        #expect(history.count == 0)
        #expect(history.popNewest() == nil)
    }

    // MARK: - P1 regression: history must hold leases WEAKLY

    /// The lease's finalize handler is the ONLY thing that tears down a
    /// detached session. That must run once the undo registration that
    /// captured the lease strongly is dropped (`ExpiringTarget.expire()` in
    /// production) — never be blocked by `ClosedTabHistory` itself holding a
    /// second, permanent strong reference.
    @Test func droppingTheSoleStrongOwnerFinalizesAndEndsFastPathEligibility() throws {
        let history = ClosedTabHistory()
        let a = makeSession()
        var tornDownIDs: [UUID] = []
        var lease: DetachedUndoLease<TerminalSessionState>? = DetachedUndoLease(payload: a) { session in
            tornDownIDs.append(session.id)
        }
        history.recordSingle(record(), lease: lease!)

        let entry = try #require(history.entries.last)
        #expect(entry.leaseGroup.isAllDetached)

        // Simulate the undo registration being dropped (the lease's sole
        // remaining strong owner in production); here that owner is this
        // local.
        lease = nil

        // Teardown ran from `DetachedUndoLease.deinit` because nothing else
        // was strongly retaining it.
        #expect(tornDownIDs == [a.id])

        // A nil (already-finalized) lease is no longer fast-path eligible —
        // treated exactly like a non-detached one.
        #expect(entry.leaseGroup.isAllDetached == false)
        #expect(entry.leaseGroup.isSpent == false)
        #expect(entry.leaseGroup.consumeAll() == nil)
    }

    // MARK: - Ring cap / eviction

    @Test func ringCapsAtCapacityAndEvictsOldestFirst() throws {
        let history = ClosedTabHistory()
        var sessions: [TerminalSessionState] = []
        var leases: [DetachedUndoLease<TerminalSessionState>] = []
        for _ in 0..<(ClosedTabHistory.capacity + 5) {
            let s = makeSession()
            sessions.append(s)
            let lease = DetachedUndoLease(payload: s) { $0.tearDown() }
            leases.append(lease)
            history.recordSingle(record(), lease: lease)
        }

        #expect(history.count == ClosedTabHistory.capacity)

        // The newest recorded entry must still be the one that pops first —
        // eviction removed the OLDEST 5, not the newest.
        let popped = try #require(history.popNewest())
        let poppedSessions = try #require(popped.leaseGroup.consumeAll())
        #expect(poppedSessions.first === sessions.last)
    }

    // MARK: - Fast path (every lease detached)

    @Test func fastPathConsumesEveryLeaseInOrderWhenAllDetached() throws {
        let history = ClosedTabHistory()
        let a = makeSession()
        let b = makeSession()
        let leaseA = DetachedUndoLease(payload: a) { $0.tearDown() }
        let leaseB = DetachedUndoLease(payload: b) { $0.tearDown() }
        history.recordGroup([
            (record(), leaseA),
            (record(), leaseB),
        ])

        let entry = try #require(history.popNewest())
        #expect(entry.leaseGroup.isAllDetached)

        let sessions = try #require(entry.leaseGroup.consumeAll())
        #expect(sessions.count == 2)
        #expect(sessions[0] === a)
        #expect(sessions[1] === b)
    }

    @Test func singleRecordFastPathReturnsExactlyOneSession() throws {
        let history = ClosedTabHistory()
        let a = makeSession()
        let lease = DetachedUndoLease(payload: a) { $0.tearDown() }
        history.recordSingle(record(), lease: lease)

        let entry = try #require(history.popNewest())
        #expect(entry.leaseGroup.isAllDetached)
        let sessions = entry.leaseGroup.consumeAll()
        #expect(sessions?.count == 1)
        #expect(sessions?.first === a)
    }

    // MARK: - All-or-nothing fallback

    @Test func groupIsNotAllDetachedIfAnySingleLeaseWasFinalized() {
        let history = ClosedTabHistory()
        let a = makeSession()
        let b = makeSession()
        let c = makeSession()
        let leaseA = DetachedUndoLease(payload: a) { $0.tearDown() }
        let leaseB = DetachedUndoLease(payload: b) { $0.tearDown() }
        let leaseC = DetachedUndoLease(payload: c) { $0.tearDown() }
        history.recordGroup([(record(), leaseA), (record(), leaseB), (record(), leaseC)])

        // Simulate lease B's undo grace window elapsing on its own.
        leaseB.finalize()

        let entry = history.popNewest()
        #expect(entry?.leaseGroup.isAllDetached == false)
    }

    @Test func consumeAllReturnsNilWhenNotEveryLeaseIsDetached() {
        let history = ClosedTabHistory()
        let a = makeSession()
        let b = makeSession()
        let leaseA = DetachedUndoLease(payload: a) { $0.tearDown() }
        let leaseB = DetachedUndoLease(payload: b) { $0.tearDown() }
        history.recordGroup([(record(), leaseA), (record(), leaseB)])

        leaseB.finalize()
        let entry = history.popNewest()
        // The caller must never consume "most of" a group.
        #expect(entry?.leaseGroup.consumeAll() == nil)
        // A must still be alive (not torn down) since it was never consumed
        // or finalized by this call.
        #expect(leaseA.state == .detached)
    }

    @Test func finalizeAllTearsDownEveryStillDetachedLeaseExactlyOnce() {
        let history = ClosedTabHistory()
        var tornDown: Set<UUID> = []
        let a = makeSession()
        let b = makeSession()
        let leaseA = DetachedUndoLease(payload: a) { session in tornDown.insert(session.id) }
        let leaseB = DetachedUndoLease(payload: b) { session in tornDown.insert(session.id) }
        history.recordGroup([
            (record(), leaseA),
            (record(), leaseB),
        ])

        let entry = try! #require(history.popNewest())
        entry.leaseGroup.finalizeAll()
        #expect(tornDown == [a.id, b.id])

        // Idempotent — a second finalizeAll must not double-tear-down.
        entry.leaseGroup.finalizeAll()
        #expect(tornDown == [a.id, b.id])
    }

    // MARK: - Record round-trip (what a fallback reopen can honestly restore)

    @Test func recordCarriesRestorationMetadataButNoLiveState() {
        let wsID = UUID()
        let rec = record(
            workspaceID: wsID,
            index: 3,
            pwd: "/Users/test",
            titleOverride: "My Tab",
            tabColor: .teal)

        #expect(rec.workspaceID == wsID)
        #expect(rec.index == 3)
        #expect(rec.pwd == "/Users/test")
        #expect(rec.titleOverride == "My Tab")
        #expect(rec.tabColor == .teal)
    }
}
