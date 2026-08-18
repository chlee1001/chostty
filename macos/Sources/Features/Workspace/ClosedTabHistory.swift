import Foundation

/// Per-controller record of destructively-closed tabs, ordered strictly by
/// close recency.
///
/// `ClosedTabHistory` is the SOLE authority for Cmd+Shift+T
/// (``BaseTerminalController/reopenClosedTab()``). The app-wide `undoManager`
/// (via `windowWillReturnUndoManager`, falling back to the app delegate's) is
/// a single process-wide stack that ALSO carries New Window, New Tab, Close
/// Tab, Close Workspace, Move Split, Close Other Tabs and Close Tabs to the
/// Right — a blind `undoManager.undo()` would pop whichever of those happens
/// to be on top, which is very often not "reopen the tab I just closed" (e.g.
/// it could un-split a pane instead). This type tracks close order
/// independently of that shared stack.
///
/// Entries are either a single closed tab or a same-close group (Close
/// Workspace, Close Other Tabs, Close Tabs to the Right), each carrying a
/// monotonic close-sequence number. The ring is bounded to ``capacity`` and
/// evicts the oldest entry first. Not persisted to v8 this phase.
final class ClosedTabHistory {
    /// Ring capacity. Oldest entries are evicted first once exceeded.
    static let capacity = 25

    /// Value-only metadata for one closed tab, captured at close time.
    ///
    /// Deliberately does NOT carry scrollback or process state — a reopen
    /// that takes the fallback path (see ``LeaseGroup``) restores only
    /// working directory, title/override, color and the recorded index; the
    /// original PTY is gone.
    struct Record {
        let workspaceID: UUID
        let workspaceName: String
        let index: Int?
        let title: String
        let titleOverride: String?
        let pwd: String?
        let tabColor: TerminalTabColor

        /// The fallback reopen path mints a new session, so this lets a pane
        /// layout still waiting to be hydrated follow the tab to its new
        /// identity instead of being stranded under the old key.
        var tabID: UUID?

        /// Returns a copy with `index` replaced. Used to normalize a
        /// multi-close batch's per-tab records to their ORIGINAL absolute
        /// index (captured before any removal in the batch), so grouped
        /// reopen's ascending forward insertion reproduces the original tab
        /// order for both `closeWorkspace` (which already records absolute
        /// indices) and the multi-close paths (which otherwise record
        /// indices already shifted by earlier removals in the same batch).
        func withIndex(_ index: Int?) -> Self {
            Record(
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                index: index,
                title: title,
                titleOverride: titleOverride,
                pwd: pwd,
                tabColor: tabColor,
                tabID: tabID)
        }
    }

    /// Owns the detached payload(s) behind one or more ``Record``s and
    /// reports/consumes/finalizes them as a single atomic unit.
    ///
    /// A same-close group (Close Workspace, Close Other Tabs, Close Tabs to
    /// the Right) either fully reopens with every original live session
    /// intact, or entirely falls back to fresh tabs — it never partially
    /// resurrects a group. Sharing the SAME underlying
    /// ``DetachedUndoLease``s that the ordinary `Cmd+Z` undo path already
    /// registered means the two mechanisms observe the SAME lease objects, so
    /// this entry can tell what actually happened to its sessions.
    ///
    /// The three lease states are not interchangeable:
    /// - `.detached` — nobody took the session; the fast path can restore the
    ///   original live process.
    /// - `.consumed` — some OTHER undo action already took the session and put
    ///   it back on screen. The entry is SPENT; reopening it again would insert
    ///   a duplicate of a tab the user can already see.
    /// - `.finalized` — the session was torn down and the process is gone. A
    ///   fresh tab built from the recorded metadata is the correct fallback.
    ///
    /// Conflating the last two is what made close-other-tabs, `Cmd+Z`, then
    /// reopen leave five tabs where there should be three.
    protocol LeaseGroup: AnyObject {
        /// True only when every underlying lease is still detached (undo has
        /// not consumed or expired ANY of them).
        var isAllDetached: Bool { get }

        /// True when any underlying lease was consumed, meaning its session was
        /// already restored by another undo and must not be recreated.
        var isSpent: Bool { get }

        /// Consumes every underlying lease exactly once, in the same order as
        /// the entry's `records`. Returns `nil` (consuming nothing) unless
        /// every lease yields a live session.
        func consumeAll() -> [TerminalSessionState]?

        /// Idempotently finalizes every underlying lease.
        func finalizeAll()
    }

    /// One history entry: either a single closed tab or a same-close group of
    /// them, in tab order.
    struct Entry {
        let sequence: UInt64
        let records: [Record]
        let leaseGroup: LeaseGroup
    }

    private(set) var entries: [Entry] = []
    private var nextSequence: UInt64 = 0

    /// Number of entries currently retained.
    var count: Int { entries.count }

    /// Records a single closed tab (the ordinary `closeWorkspaceTab` path).
    @discardableResult
    func recordSingle(
        _ record: Record,
        lease: DetachedUndoLease<TerminalSessionState>
    ) -> Entry {
        push(Entry(
            sequence: takeSequence(),
            records: [record],
            leaseGroup: SingleLeaseGroup(lease: lease)))
    }

    /// Records a same-close group of tabs (Close Workspace, Close Other Tabs,
    /// Close Tabs to the Right), in tab order. No-op if `records` is empty.
    @discardableResult
    func recordGroup(
        _ records: [(Record, DetachedUndoLease<TerminalSessionState>)]
    ) -> Entry? {
        guard !records.isEmpty else { return nil }
        let leaseGroup = MultiLeaseGroup(leases: records.map(\.1))
        return push(Entry(
            sequence: takeSequence(),
            records: records.map(\.0),
            leaseGroup: leaseGroup))
    }

    /// Pops the newest entry by CLOSE RECENCY — not undo-stack top. Returns
    /// `nil` if history is empty.
    func popNewest() -> Entry? {
        entries.popLast()
    }

    private func takeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    @discardableResult
    private func push(_ entry: Entry) -> Entry {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        return entry
    }
}

/// Wraps a single per-tab lease from the ordinary `closeWorkspaceTab` path.
///
/// Holds the lease WEAKLY. The lease's finalize handler is the ONLY thing
/// that tears down the detached session (PTY, surfaces, live-registry entry)
/// — normally run from `DetachedUndoLease.deinit` once the undo registration
/// that captured it strongly is dropped by `ExpiringTarget.expire()`. If
/// history held it strongly instead, it would become a second, permanent
/// strong owner: `deinit` would never fire, the finalize teardown would
/// never run, and up to `ClosedTabHistory.capacity` closed tabs per
/// controller would keep live PTYs and child processes around forever. A nil
/// lease (already deinitialized/finalized this way) is treated exactly like
/// a non-detached one below.
private final class SingleLeaseGroup: ClosedTabHistory.LeaseGroup {
    private weak var lease: DetachedUndoLease<TerminalSessionState>?

    init(lease: DetachedUndoLease<TerminalSessionState>) {
        self.lease = lease
    }

    var isAllDetached: Bool { lease?.state == .detached }

    var isSpent: Bool { lease?.state == .consumed }

    func consumeAll() -> [TerminalSessionState]? {
        guard let session = lease?.consume() else { return nil }
        return [session]
    }

    func finalizeAll() {
        lease?.finalize()
    }
}

/// Thin box giving a weak reference to a `DetachedUndoLease` a place to live
/// inside an `Array` — Swift arrays cannot hold `weak` elements directly.
private final class WeakLeaseBox {
    weak var lease: DetachedUndoLease<TerminalSessionState>?

    init(_ lease: DetachedUndoLease<TerminalSessionState>) {
        self.lease = lease
    }
}

/// Wraps N per-tab leases detached together by one same-close group (Close
/// Workspace, Close Other Tabs, Close Tabs to the Right), in tab order.
///
/// Each lease is held WEAKLY (via `WeakLeaseBox`) for the same reason as
/// `SingleLeaseGroup` — see its doc.
private final class MultiLeaseGroup: ClosedTabHistory.LeaseGroup {
    private let leases: [WeakLeaseBox]

    init(leases: [DetachedUndoLease<TerminalSessionState>]) {
        self.leases = leases.map(WeakLeaseBox.init)
    }

    var isAllDetached: Bool { leases.allSatisfy { $0.lease?.state == .detached } }

    var isSpent: Bool { leases.contains { $0.lease?.state == .consumed } }

    func consumeAll() -> [TerminalSessionState]? {
        // All-or-nothing: check every lease is still detached BEFORE
        // consuming any of them. Otherwise a failure partway through the loop
        // would leave earlier leases consumed while the caller believes
        // nothing was, breaking `consumeAll`'s "consumes nothing" contract on
        // failure.
        guard isAllDetached else { return nil }
        var sessions: [TerminalSessionState] = []
        sessions.reserveCapacity(leases.count)
        for box in leases {
            guard let session = box.lease?.consume() else { return nil }
            sessions.append(session)
        }
        return sessions
    }

    func finalizeAll() {
        for box in leases {
            box.lease?.finalize()
        }
    }
}
