import AppKit
import Foundation
import OSLog

/// Decides when a session snapshot is written, and writes it.
///
/// Structural edits use a trailing debounce. The periodic timer captures
/// terminal title and working-directory metadata without serializing every
/// shell event.
///
/// Change detection never touches `commit(_:)`. Two counters that already exist
/// answer the question: `WorkspaceSessionStore.mountGeneration` covers
/// structural change routed through the store, and
/// `TerminalSessionState.metadataGeneration` covers titles, directories, rename,
/// tab color, and the direct tree assignments (split create, close, resize,
/// zoom) that bypass `commit` entirely through `surfaceTree`'s `didSet`.
///
/// When neither counter moved since the last successful save and the window
/// set is unchanged, a triggered save does no projection at all.
@MainActor
final class SessionPersistenceController {
    /// Target save cadence, not a durability guarantee: failed writes keep the
    /// last valid snapshot and retry on later ticks.
    static let interval: TimeInterval = 8.0
    static let saveDebounce: TimeInterval = 1.0
    static let healthDidChange = Notification.Name("kr.co.devch.chostty.sessionPersistence.healthDidChange")

    enum SaveHealth: Equatable {
        case healthy
        case refused(SessionSnapshotValidator.Rejection)
        case failing(consecutiveFailures: Int)
    }

    private let repository: SessionSnapshotRepository
    private let gate: SessionPersistenceGate
    private let registry: PendingHydrationRegistry
    private let controllersProvider: () -> [TerminalController]
    private let ownerInstanceID: UUID
    private let ownerPID: Int32

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "kr.co.devch.chostty",
        category: "session-persistence"
    )

    /// Keeps the timer path and the terminate path from interleaving on the
    /// same file. Tests may inject another serial utility queue.
    private let queue: DispatchQueue

    private var timer: Timer?
    private var scheduledSaveGeneration: UInt = 0
    private var pendingSaveGeneration: UInt?
    private var isTerminating = false

    private struct SaveCursor: Equatable, Sendable {
        var mountGenerations: [UUID: UInt64] = [:]
        var metadataGenerations: [UUID: UInt64] = [:]
        var windowIDs: Set<UUID> = []
    }

    /// The main actor reserves cursors without waiting for filesystem I/O.
    /// Queue completions acknowledge only their own cursor, under the same lock.
    /// A refused cursor is not retried until it changes, at which point it is
    /// evaluated again.
    private final class SaveState: @unchecked Sendable {
        enum Result: Sendable {
            case saved
            case rejected(SessionSnapshotValidator.Rejection)
            case failed
            case yielded
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
            case .failed, .yielded:
                break
            }
            inFlightCursors.removeAll { $0 == cursor }
        }
    }

    private let saveState = SaveState()
    private var consecutiveSaveFailures = 0
    private(set) var saveHealth: SaveHealth = .healthy

    /// PID of the other live instance that owns the file. While set, this
    /// process neither saves nor overwrites until that owner exits or the user
    /// takes ownership back.
    private(set) var foreignOwnerPID: Int32?

    var isDisabledBySecondInstance: Bool { foreignOwnerPID != nil }

    private let isLiveInstance: (Int32) -> Bool
    private let scheduleAfter: MainScheduler
    private let uptime: () -> UInt64

    static let restoreAttemptSettleDelay: TimeInterval = 2.0
    private(set) var restoreAttemptsUnavailable = false
    private(set) var restoreAttemptStarts = 0

    init(
        repository: SessionSnapshotRepository,
        gate: SessionPersistenceGate,
        registry: PendingHydrationRegistry,
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        queue: DispatchQueue = DispatchQueue(label: "kr.co.devch.chostty.session-persistence", qos: .utility),
        isLiveInstance: @escaping (Int32) -> Bool = SessionPersistenceController.isLiveAppInstance,
        scheduleAfter: @escaping MainScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        uptime: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
        controllersProvider: @escaping () -> [TerminalController] = { TerminalController.open }
    ) {
        self.repository = repository
        self.gate = gate
        self.registry = registry
        self.ownerInstanceID = ownerInstanceID
        self.ownerPID = ownerPID
        self.queue = queue
        self.isLiveInstance = isLiveInstance
        self.scheduleAfter = scheduleAfter
        self.uptime = uptime
        self.controllersProvider = controllersProvider
    }

    // MARK: - Restore attempts

    struct RestoreAttemptToken: Hashable {
        let attemptID: UUID
        let kind: SessionSnapshotRepository.RestoreAttempt.Kind
        let targetIDs: Set<UUID>
    }

    enum RestoreAttemptStart: Equatable {
        case recorded(RestoreAttemptToken)
        case notTracked
        case unrecorded
    }

    func beginRestoreAttempt(
        _ kind: SessionSnapshotRepository.RestoreAttempt.Kind,
        _ ids: Set<UUID>
    ) -> RestoreAttemptStart {
        guard gate.shouldPersist else { return .notTracked }

        restoreAttemptStarts += 1
        let token = RestoreAttemptToken(attemptID: UUID(), kind: kind, targetIDs: ids)
        do {
            try repository.updateRestoreAttempts { attempts in
                attempts.append(contentsOf: ids.map {
                    SessionSnapshotRepository.RestoreAttempt(
                        kind: kind,
                        targetID: $0,
                        attemptID: token.attemptID,
                        ownerInstanceID: ownerInstanceID,
                        ownerPID: ownerPID,
                        startedAtUptime: uptime()
                    )
                })
            }
            setRestoreAttemptsUnavailable(false)
            return .recorded(token)
        } catch {
            setRestoreAttemptsUnavailable(true)
            Self.logger.warning(
                "session.restore.attemptNotRecorded kind=\(kind.rawValue, privacy: .public) ids=\(ids.count, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return .unrecorded
        }
    }

    func settleRestoreAttempt(
        _ token: RestoreAttemptToken,
        recovered: Set<UUID>,
        onSettled: @escaping @MainActor () -> Void = {}
    ) {
        scheduleAfter(Self.restoreAttemptSettleDelay) { [weak self] in
            self?.finishRestoreAttempt(token, recovered: recovered)
            onSettled()
        }
    }

    func finishRestoreAttempt(
        _ token: RestoreAttemptToken,
        recovered: Set<UUID> = []
    ) {
        guard gate.shouldPersist else { return }
        do {
            try repository.updateRestoreAttempts { attempts in
                attempts.removeAll { attempt in
                    if attempt.attemptID == token.attemptID {
                        return true
                    }
                    guard recovered.contains(attempt.targetID),
                          token.targetIDs.contains(attempt.targetID) else {
                        return false
                    }
                    return isDeadRestoreAttempt(attempt)
                }
            }
        } catch {
            Self.logger.warning("session.restore.attemptFinishFailed error=\(String(describing: error), privacy: .public)")
        }
    }

    func finishOwnRestoreAttempts() {
        guard gate.shouldPersist else { return }
        do {
            try repository.updateRestoreAttempts { attempts in
                attempts.removeAll { $0.ownerInstanceID == ownerInstanceID }
            }
        } catch {
            Self.logger.warning("session.restore.attemptFinishOwnFailed error=\(String(describing: error), privacy: .public)")
        }
    }

    func restoreQuarantine() -> (windows: Set<UUID>, tabs: Set<UUID>) {
        var windows = Set<UUID>()
        var tabs = Set<UUID>()
        for attempt in repository.restoreAttempts() where isDeadRestoreAttempt(attempt) {
            switch attempt.kind {
            case .window: windows.insert(attempt.targetID)
            case .tab: tabs.insert(attempt.targetID)
            }
        }
        return (windows, tabs)
    }

    func pruneRestoreAttempts(keeping ids: Set<UUID>) {
        guard gate.shouldPersist else { return }
        do {
            try repository.updateRestoreAttempts { attempts in
                attempts.removeAll { isDeadRestoreAttempt($0) && !ids.contains($0.targetID) }
            }
        } catch {
            Self.logger.warning("session.restore.attemptPruneFailed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func isDeadRestoreAttempt(_ attempt: SessionSnapshotRepository.RestoreAttempt) -> Bool {
        attempt.ownerInstanceID != ownerInstanceID
            && (!isLiveInstance(attempt.ownerPID) || attempt.startedAtUptime > uptime())
    }

    private func setRestoreAttemptsUnavailable(_ unavailable: Bool) {
        guard restoreAttemptsUnavailable != unavailable else { return }
        restoreAttemptsUnavailable = unavailable
        NotificationCenter.default.post(name: Self.healthDidChange, object: self)
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

    /// Schedules a structural save after changes have stopped arriving.
    func scheduleSave() {
        guard gate.shouldPersist, !isTerminating else { return }
        scheduledSaveGeneration &+= 1
        let generation = scheduledSaveGeneration
        pendingSaveGeneration = generation
        scheduleAfter(Self.saveDebounce) { [weak self] in
            guard let self,
                  self.pendingSaveGeneration == generation,
                  !self.isTerminating else { return }
            self.pendingSaveGeneration = nil
            _ = self.persistIfNeeded()
        }
    }

    /// Captures the complete live window projection before close notifications
    /// can remove any controllers, then prevents later lifecycle events from
    /// replacing it with a partial projection.
    func beginTermination() {
        guard !isTerminating else { return }
        pendingSaveGeneration = nil
        scheduledSaveGeneration &+= 1
        persistNow()
        isTerminating = true
    }

    /// Reopens structural persistence after AppKit cancels termination.
    func cancelTermination() {
        guard isTerminating else { return }
        isTerminating = false
        scheduleSave()
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
        guard !isTerminating else { return false }
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
        guard !isTerminating else { return }
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
        let work = { () -> SaveState.Result in
            var result = SaveState.Result.failed
            do {
                switch try repository.save(snapshot) {
                case .written, .skippedIdentical:
                    result = .saved
                case .refusedInvalid(let rejection):
                    result = .rejected(rejection)
                }
            } catch {
                // A failed write is retried on the next tick; the previous file
                // is still on disk and still usable.
                Self.logger.warning("session.persist.writeFailed \(String(describing: error), privacy: .public)")
            }
            saveState.finish(cursor, result: result)
            return result
        }

        if synchronously {
            applySaveResult(queue.sync(execute: work))
        } else {
            queue.async { [weak self] in
                let result = work()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.applySaveResult(result)
                    }
                }
            }
        }
    }

    private func applySaveResult(_ result: SaveState.Result) {
        let oldHealth = saveHealth
        switch result {
        case .saved:
            consecutiveSaveFailures = 0
            saveHealth = .healthy
        case .rejected(let rejection):
            saveHealth = .refused(rejection)
        case .failed:
            consecutiveSaveFailures += 1
            if consecutiveSaveFailures >= 3 {
                saveHealth = .failing(consecutiveFailures: consecutiveSaveFailures)
            }
        case .yielded:
            break
        }

        let newHealth = saveHealth
        guard oldHealth != newHealth else { return }
        Self.logger.notice(
            "session.persist.health from=\(String(describing: oldHealth), privacy: .public) to=\(String(describing: newHealth), privacy: .public)"
        )
        NotificationCenter.default.post(name: Self.healthDidChange, object: self)
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
        for controller in controllers {
            for workspace in controller.workspaceStore.snapshot.workspaces {
                for session in workspace.tabs
                where session.surfaceTree.isEmpty && pending[session.id] == nil {
                    // Observation only: test fixtures can deliberately create
                    // this state even though normal restoration should not.
                    Self.logger.warning("session.persist.emptyLiveTab tab=\(session.id, privacy: .public)")
                }
            }
        }
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
