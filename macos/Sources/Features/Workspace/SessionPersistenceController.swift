import AppKit
import Foundation
import OSLog

/// Decides when a session snapshot is written, and writes it.
///
/// The trigger is a timer, never a shell event. That is the difference against
/// the two restoration attempts this fork removed: those re-serialized the
/// whole graph on every title and working-directory change a shell emitted.
/// Here the save rate has a hard ceiling of once per ``interval`` no matter how
/// noisy the terminal is.
///
/// Change detection never touches `commit(_:)`. Two counters that already exist
/// answer the question: `WorkspaceSessionStore.mountGeneration` covers
/// structural change routed through the store, and
/// `TerminalSessionState.metadataGeneration` covers titles, directories, rename,
/// tab color, and the direct tree assignments (split create, close, resize,
/// zoom) that bypass `commit` entirely through `surfaceTree`'s `didSet`.
///
/// When neither counter moved since the last successful save and the window
/// set is unchanged, a tick does no projection at all.
@MainActor
final class SessionPersistenceController {
    /// Target save cadence, not a durability guarantee: refused or failed
    /// writes keep the last valid snapshot and retry on later ticks.
    static let interval: TimeInterval = 8.0

    private let repository: SessionSnapshotRepository
    private let gate: SessionPersistenceGate
    private let registry: PendingHydrationRegistry
    private let controllersProvider: () -> [TerminalController]
    private let ownerInstanceID: UUID
    private let ownerPID: Int32

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.chostty.app",
        category: "session-persistence"
    )

    /// Keeps the timer path and the terminate path from interleaving on the
    /// same file. Tests may inject another serial utility queue.
    private let queue: DispatchQueue

    private var timer: Timer?

    private struct SaveCursor: Equatable, Sendable {
        var mountGenerations: [UUID: UInt64] = [:]
        var metadataGenerations: [UUID: UInt64] = [:]
        var windowIDs: Set<UUID> = []
    }

    /// The main actor reserves cursors without waiting for filesystem I/O.
    /// Queue completions acknowledge only their own cursor, under the same lock.
    private final class SaveState: @unchecked Sendable {
        enum Result {
            case saved
            case rejected
            case failed
        }

        private let lock = NSLock()
        /// `nil` forces the first successful write to record this process's
        /// fresh owner ID even when the graph has not changed.
        private var savedCursor: SaveCursor?
        private var rejectedCursor: SaveCursor?
        private var inFlightCursors: [SaveCursor] = []

        func reserve(_ cursor: SaveCursor) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard savedCursor != cursor,
                  rejectedCursor != cursor,
                  !inFlightCursors.contains(cursor) else { return false }
            inFlightCursors.append(cursor)
            return true
        }

        /// After an ownership change the file may hold another writer's graph,
        /// so the next tick must write even when this process saw no change.
        func forgetCompletedSaves() {
            lock.lock()
            defer { lock.unlock() }
            savedCursor = nil
            rejectedCursor = nil
        }

        func finish(_ cursor: SaveCursor, result: Result) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .saved:
                savedCursor = cursor
                rejectedCursor = nil
            case .rejected:
                rejectedCursor = cursor
            case .failed:
                break
            }
            inFlightCursors.removeAll { $0 == cursor }
        }
    }

    private let saveState = SaveState()

    /// PID of the other live instance that owns the file. While set, this
    /// process neither saves nor overwrites until that owner exits or the user
    /// takes ownership back.
    private(set) var foreignOwnerPID: Int32?

    var isDisabledBySecondInstance: Bool { foreignOwnerPID != nil }

    private let isLiveInstance: (Int32) -> Bool

    init(
        repository: SessionSnapshotRepository,
        gate: SessionPersistenceGate,
        registry: PendingHydrationRegistry,
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        queue: DispatchQueue = DispatchQueue(label: "com.chostty.session-persistence", qos: .utility),
        isLiveInstance: @escaping (Int32) -> Bool = SessionPersistenceController.isLiveAppInstance,
        controllersProvider: @escaping () -> [TerminalController] = { TerminalController.all }
    ) {
        self.repository = repository
        self.gate = gate
        self.registry = registry
        self.ownerInstanceID = ownerInstanceID
        self.ownerPID = ownerPID
        self.queue = queue
        self.isLiveInstance = isLiveInstance
        self.controllersProvider = controllersProvider
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        guard gate.shouldPersist, timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.persistIfNeeded()
            }
        }
        // Saving must keep up while a menu or a resize is tracking the run loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The timer keeps running while passive: its ticks are what notice the
    /// owner exiting.
    func disableForSecondInstance(ownerPID: Int32) {
        foreignOwnerPID = ownerPID
        Self.logger.notice("session.persist.disabledSecondInstance ownerPID=\(ownerPID, privacy: .public)")
    }

    /// A pid alone is not an identity. After a reboot the recorded pid can
    /// belong to an unrelated root daemon, which `kill(pid, 0)` reports as
    /// alive through `EPERM`. Only a running application with this app's
    /// bundle identifier counts. Debug and release builds have different
    /// identifiers and directories, so they never share a file.
    static func isLiveAppInstance(_ pid: Int32) -> Bool {
        guard pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = Bundle.main.bundleIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { return false }
        return app.bundleIdentifier == bundleIdentifier
    }

    /// Decides at boot whether another live instance owns the file.
    ///
    /// Both conditions are required. An instance-id mismatch alone is true on
    /// every ordinary relaunch, since a new id is issued per process and the
    /// previous run always saves on quit; keying off it would switch
    /// persistence off from the second launch onward and freeze the user's
    /// layout at whatever the first run wrote.
    @discardableResult
    func adoptOwnership(of stored: AppSessionSnapshot?) -> Bool {
        guard let stored else { return false }
        return yields(to: SessionSnapshotRepository.StoredOwner(
            ownerInstanceID: stored.ownerInstanceID,
            ownerPID: stored.ownerPID
        ))
    }

    /// Goes passive when the recorded writer is a different, live instance.
    /// Checked before every write too, which is what makes a takeover by the
    /// other instance stick instead of the two alternately overwriting.
    private func yields(to stored: SessionSnapshotRepository.StoredOwner?) -> Bool {
        guard let stored,
              stored.ownerInstanceID != ownerInstanceID,
              isLiveInstance(stored.ownerPID) else { return false }
        disableForSecondInstance(ownerPID: stored.ownerPID)
        return true
    }

    /// Resumes saving once the instance this process deferred to has exited.
    func reconcileOwnership() {
        guard let foreignOwnerPID, !isLiveInstance(foreignOwnerPID) else { return }
        self.foreignOwnerPID = nil
        saveState.forgetCompletedSaves()
        Self.logger.notice("session.persist.ownerExited ownerPID=\(foreignOwnerPID, privacy: .public)")
    }

    /// Writes this process's live graph over a file owned by another live
    /// instance. That instance reads the new owner before its next write and
    /// goes passive, so the takeover holds.
    @discardableResult
    func takeOverOwnership() -> SidebarSyncInspection {
        if let foreignOwnerPID {
            Self.logger.notice("session.persist.takeOver previousOwnerPID=\(foreignOwnerPID, privacy: .public)")
        }
        foreignOwnerPID = nil
        saveState.forgetCompletedSaves()
        if canPersist {
            let controllers = controllersProvider()
            if !controllers.isEmpty {
                write(snapshot(from: controllers), cursor: saveCursor(from: controllers), synchronously: true)
            }
        }
        return sidebarSyncInspection()
    }

    /// Details of the owning instance for the sync sheet.
    private func foreignOwner() -> SidebarSyncInspection.ForeignOwner? {
        guard let foreignOwnerPID else { return nil }
        let app = NSRunningApplication(processIdentifier: foreignOwnerPID)
        return SidebarSyncInspection.ForeignOwner(
            pid: foreignOwnerPID,
            bundlePath: app?.bundleURL?.path,
            launchDate: app?.launchDate
        )
    }

    // MARK: - Sidebar sync inspection

    struct SidebarSyncInspection: Equatable {
        enum Status: Equatable {
            case synchronized
            case outOfSync
            case absent
            case unusable(String)
            case liveStateUnavailable
        }

        struct ForeignOwner: Equatable {
            let pid: Int32
            let bundlePath: String?
            let launchDate: Date?
        }

        enum SynchronizationAvailability: Equatable {
            case available
            case persistenceDisabled
            case ownedByAnotherLiveInstance(ForeignOwner)
            case noLiveState
        }

        let current: AppSessionSnapshot?
        let saved: AppSessionSnapshot?
        let status: Status
        let synchronizationAvailability: SynchronizationAvailability

        var canSynchronize: Bool {
            synchronizationAvailability == .available
        }

        var foreignOwner: ForeignOwner? {
            guard case .ownedByAnotherLiveInstance(let owner) = synchronizationAvailability else { return nil }
            return owner
        }
    }

    /// Inspects the live projection and the repository's validated snapshot.
    /// Owner fields intentionally do not participate in this comparison: they
    /// describe the writer, not the workspace graph the sidebar displays.
    func sidebarSyncInspection() -> SidebarSyncInspection {
        reconcileOwnership()
        let controllers = controllersProvider()
        let current = controllers.isEmpty ? nil : snapshot(from: controllers)
        let availability = synchronizationAvailability(hasLiveState: current != nil)

        switch repository.load() {
        case .absent:
            return SidebarSyncInspection(
                current: current,
                saved: nil,
                status: current == nil ? .liveStateUnavailable : .absent,
                synchronizationAvailability: availability
            )

        case .loaded(let saved, _):
            guard let current else {
                return SidebarSyncInspection(
                    current: nil,
                    saved: saved,
                    status: .liveStateUnavailable,
                    synchronizationAvailability: availability
                )
            }
            return SidebarSyncInspection(
                current: current,
                saved: saved,
                status: current.windows == saved.windows ? .synchronized : .outOfSync,
                synchronizationAvailability: availability
            )

        case .unusable(let reason):
            return SidebarSyncInspection(
                current: current,
                saved: nil,
                status: current == nil ? .liveStateUnavailable : .unusable(reason),
                synchronizationAvailability: availability
            )
        }
    }

    /// Writes only the current live graph, then returns a freshly validated
    /// comparison. It never applies the saved graph to live terminal sessions.
    @discardableResult
    func synchronizeSidebarState() -> SidebarSyncInspection {
        let inspection = sidebarSyncInspection()
        guard inspection.canSynchronize else { return inspection }
        persistNow()
        return sidebarSyncInspection()
    }

    private func synchronizationAvailability(
        hasLiveState: Bool
    ) -> SidebarSyncInspection.SynchronizationAvailability {
        if let owner = foreignOwner() { return .ownedByAnotherLiveInstance(owner) }
        if !gate.shouldPersist { return .persistenceDisabled }
        if !hasLiveState { return .noLiveState }
        return .available
    }

    // MARK: - Saving

    /// - Returns: `true` when a projection ran. The write itself may still be
    ///   skipped because the bytes matched.
    @discardableResult
    func persistIfNeeded() -> Bool {
        reconcileOwnership()
        guard canPersist else { return false }

        let controllers = controllersProvider()
        // Closing every window is a normal macOS state, not a new restorable
        // layout. Keep the last valid snapshot without retrying an invalid
        // zero-window projection on every timer tick.
        guard !controllers.isEmpty else { return false }
        let cursor = saveCursor(from: controllers)
        guard saveState.reserve(cursor) else { return false }
        // Read only once a write is due, so an idle tick stays off the disk.
        if yields(to: repository.storedOwner()) {
            saveState.finish(cursor, result: .failed)
            return false
        }

        write(snapshot(from: controllers), cursor: cursor, synchronously: false)
        return true
    }

    /// Blocks until the save attempt finishes. Invalid projections and I/O
    /// failures leave the previous valid snapshot in place.
    func persistNow() {
        reconcileOwnership()
        guard canPersist else { return }
        let controllers = controllersProvider()
        guard !controllers.isEmpty else { return }
        guard !yields(to: repository.storedOwner()) else { return }
        write(snapshot(from: controllers), cursor: saveCursor(from: controllers), synchronously: true)
    }

    /// For tests; production does not need it, since the terminate path is
    /// synchronous.
    func flush() {
        queue.sync {}
    }

    private var canPersist: Bool {
        gate.shouldPersist && !isDisabledBySecondInstance
    }

    private func write(_ snapshot: AppSessionSnapshot, cursor: SaveCursor, synchronously: Bool) {
        let repository = self.repository
        let saveState = self.saveState
        let work = {
            var result = SaveState.Result.failed
            defer { saveState.finish(cursor, result: result) }
            do {
                switch try repository.save(snapshot) {
                case .written, .skippedIdentical:
                    result = .saved
                case .refusedInvalid:
                    result = .rejected
                }
            } catch {
                // A failed write is retried on the next tick; the previous file
                // is still on disk and still usable.
                Self.logger.warning("session.persist.writeFailed \(String(describing: error), privacy: .public)")
            }
        }

        if synchronously {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    // MARK: - Change detection

    private func saveCursor(from controllers: [TerminalController]) -> SaveCursor {
        var cursor = SaveCursor()
        cursor.windowIDs = Set(controllers.map(\.physicalUUID))
        for controller in controllers {
            let store = controller.workspaceStore
            cursor.mountGenerations[controller.physicalUUID] = store.snapshot.mountGeneration
            for session in store.allSessions {
                cursor.metadataGenerations[session.id] = session.metadataGeneration
            }
        }
        return cursor
    }

    // MARK: - Projection

    /// Reads live `NSView` state, so main-thread only; the encode and write go
    /// to the background queue.
    func snapshot(from controllers: [TerminalController]) -> AppSessionSnapshot {
        let pending = registry.allPending
        let windows = controllers
            .map { controller -> WindowSnapshot in
                let store = controller.workspaceStore
                let snapshot = store.snapshot
                return WindowSnapshot(
                    physicalUUID: controller.physicalUUID,
                    selection: SelectionSnapshot(
                        workspaceID: snapshot.selection.workspaceID,
                        tabID: snapshot.selection.tabID
                    ),
                    workspaces: snapshot.workspaces.map {
                        SessionSnapshotProjection.workspace(from: $0, pendingTabs: pending)
                    }
                )
            }
            // `TerminalController.all` derives from `NSApp.windows`, whose order
            // is not stable. Sorting by the window's own identity keeps the
            // encoded bytes stable so the identical-bytes skip can fire.
            .sorted { $0.physicalUUID.uuidString < $1.physicalUUID.uuidString }

        return AppSessionSnapshot(
            ownerInstanceID: ownerInstanceID,
            ownerPID: ownerPID,
            windows: windows
        )
    }
}
