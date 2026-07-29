import Foundation

/// Exclusive owner of resources that a destructive close has removed from every
/// live store and registry.
///
/// A lease has three states — `detached`, `consumed`, `finalized` — and exactly
/// one of two fates:
///
/// - **Undo runs:** `consume()` transfers the payload out exactly once. The
///   caller re-registers it, so the payload stays alive and its PTY keeps
///   running. A second `consume()` yields `nil`.
/// - **Undo expires or is discarded:** `finalize()` runs the caller-supplied
///   teardown exactly once. `finalize()` is idempotent, is called from `deinit`,
///   and does nothing after a `consume()` because the lease no longer owns the
///   payload.
///
/// `Payload` is whatever the close path detached — today
/// `TerminalSessionState` for a tab and `[TerminalSessionState]` for a
/// workspace. The teardown closure is responsible for both destroying the
/// resource and dropping it from the store's live-session registry; the lease
/// itself knows nothing about either.
final class DetachedUndoLease<Payload> {

    // MARK: State

    enum State {
        case detached
        case consumed
        case finalized
    }

    private(set) var state: State = .detached

    /// The payload owned by this lease. Nil after consume or finalize.
    private(set) var payload: Payload?

    /// Called exactly once during finalization to tear down payload resources.
    private let finalizeHandler: (Payload) -> Void

    // MARK: Init

    init(payload: Payload, finalizeHandler: @escaping (Payload) -> Void) {
        self.payload = payload
        self.finalizeHandler = finalizeHandler
    }

    // MARK: Lifecycle

    /// Transfers the payload exactly once. Returns nil if already consumed or finalized.
    @discardableResult
    func consume() -> Payload? {
        guard state == .detached else { return nil }
        state = .consumed
        let p = payload
        payload = nil
        return p
    }

    /// Idempotently finalizes: runs the teardown closure exactly once.
    func finalize() {
        guard state != .finalized else { return }
        state = .finalized
        if let p = payload {
            payload = nil
            finalizeHandler(p)
        }
    }

    deinit {
        finalize()
    }
}
