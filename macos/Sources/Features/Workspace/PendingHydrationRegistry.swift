import Foundation
import OSLog

typealias MainScheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

enum HydrationOutcome: Equatable {
    case hydrated(panes: Int)
    case notPending
    case alreadyLive
    case notInStore
    case heldBack
    case unrecorded
    case failed
}

/// Pane trees for tabs that were restored from disk but not yet turned into
/// live surfaces.
///
/// Boot materializes only the selected tab of the selected workspace; the rest
/// wait here until first selected. The save path must be able to read this map:
/// a pending tab's live tree is empty by construction, so projecting it from
/// the live graph would write "this tab has no panes" and, one timer tick
/// later, erase the structure of every tab the user had not opened.
///
/// Owned by the application rather than a window controller. Closing a window
/// and undoing it rebuilds a new controller around the same live sessions, and
/// a controller-owned map would die with the old one. Keying by tab UUID also
/// survives `store.moveTab`, which only reorders within a store.
@MainActor
final class PendingHydrationRegistry {
    private var entries: [UUID: TabSnapshot] = [:]
    private static var logger: Logger { SessionPersistenceController.logger }

    // MARK: - Paced hydration

    static let hydrationStepInterval: TimeInterval = 0.15

    private final class WeakOwner {
        weak var value: AnyObject?

        init(_ value: AnyObject) {
            self.value = value
        }
    }

    private struct QueuedHydration {
        var tabID: UUID
        let ownerID: ObjectIdentifier
        let owner: WeakOwner
        let hydrate: @MainActor (UUID) -> HydrationOutcome
    }

    private let scheduleAfter: MainScheduler
    private var hydrationQueue: [QueuedHydration] = []
    private var stepScheduled = false

    init(
        scheduleAfter: @escaping MainScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.scheduleAfter = scheduleAfter
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func store(_ snapshot: TabSnapshot, for tabID: UUID) {
        entries[tabID] = snapshot
    }

    func snapshot(for tabID: UUID) -> TabSnapshot? {
        entries[tabID]
    }

    func contains(_ tabID: UUID) -> Bool {
        entries[tabID] != nil
    }

    /// Called only after successful hydration, or to discard a stale entry
    /// whose tab already owns a live tree.
    @discardableResult
    func take(_ tabID: UUID) -> TabSnapshot? {
        entries.removeValue(forKey: tabID)
    }

    /// Reopening a closed tab can mint a fresh session, so the pending
    /// structure has to follow it rather than being stranded under the old key.
    func rekey(from oldID: UUID, to newID: UUID) {
        if let entry = entries.removeValue(forKey: oldID) {
            entries[newID] = TabSnapshot(
                id: newID,
                titleOverride: entry.titleOverride,
                tabColor: entry.tabColor,
                paneTree: entry.paneTree,
                focusedPaneID: entry.focusedPaneID,
                zoomedPaneID: entry.zoomedPaneID
            )
        }
        for index in hydrationQueue.indices where hydrationQueue[index].tabID == oldID {
            hydrationQueue[index].tabID = newID
        }
    }

    func enqueueHydration(
        _ tabIDs: [UUID],
        owner: AnyObject,
        hydrate: @escaping @MainActor (UUID) -> HydrationOutcome
    ) {
        var seen = Set(hydrationQueue.map(\.tabID))
        let eligible = tabIDs.filter { tabID in
            guard contains(tabID), !seen.contains(tabID) else { return false }
            seen.insert(tabID)
            return true
        }
        guard !eligible.isEmpty else { return }

        let ownerID = ObjectIdentifier(owner)
        let additions = eligible.map {
            QueuedHydration(tabID: $0, ownerID: ownerID, owner: WeakOwner(owner), hydrate: hydrate)
        }
        let wasEmpty = hydrationQueue.isEmpty
        hydrationQueue.insert(contentsOf: additions, at: 0)
        if wasEmpty {
            scheduleStep(after: 0)
        }
    }

    func cancelHydration(owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        let queued = hydrationQueue.count
        hydrationQueue.removeAll { $0.ownerID == ownerID }
        logCancelled(queued - hydrationQueue.count, scope: "window")
    }

    func cancelAllHydration() {
        let queued = hydrationQueue.count
        hydrationQueue.removeAll()
        logCancelled(queued, scope: "all")
    }

    private func logCancelled(_ count: Int, scope: String) {
        guard count > 0 else { return }
        Self.logger.notice(
            "session.hydrate.cancelled scope=\(scope, privacy: .public) tabs=\(count, privacy: .public)"
        )
    }

    private func scheduleStep(after delay: TimeInterval) {
        guard !stepScheduled else { return }
        stepScheduled = true
        scheduleAfter(delay) { [weak self] in
            self?.runHydrationStep()
        }
    }

    private func runHydrationStep() {
        stepScheduled = false
        while !hydrationQueue.isEmpty {
            let item = hydrationQueue.removeFirst()
            guard item.owner.value != nil else { continue }
            guard contains(item.tabID) else { continue }

            let start = ProcessInfo.processInfo.systemUptime
            let outcome = item.hydrate(item.tabID)
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            switch outcome {
            case .notPending, .alreadyLive, .notInStore, .heldBack:
                continue
            case .hydrated(let panes):
                let delay = Self.hydrationStepInterval * Double(max(1, panes))
                let queued = hydrationQueue.count
                Self.logger.debug(
                    "session.hydrate.step tab=\(item.tabID.uuidString, privacy: .public) panes=\(panes, privacy: .public) ms=\(elapsed, privacy: .public) queued=\(queued, privacy: .public) nextDelayMs=\(Int(delay * 1_000), privacy: .public)"
                )
                scheduleStep(after: delay)
                return
            case .failed, .unrecorded:
                let remaining = hydrationQueue.filter { $0.ownerID == item.ownerID }.count
                hydrationQueue.removeAll { $0.ownerID == item.ownerID }
                let reason = outcome == .failed ? "failed" : "attemptNotRecorded"
                Self.logger.warning(
                    "session.hydrate.drainStopped owner=\(String(describing: item.ownerID), privacy: .public) remaining=\(remaining, privacy: .public) reason=\(reason, privacy: .public)"
                )
                if !hydrationQueue.isEmpty {
                    scheduleStep(after: 0)
                }
                return
            }
        }
    }

    /// For the save path.
    var allPending: [UUID: TabSnapshot] { entries }
}
