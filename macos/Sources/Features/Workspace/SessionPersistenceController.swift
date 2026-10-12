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
    static let dormantWindowsDidChange = Notification.Name("kr.co.devch.chostty.sessionPersistence.dormantWindowsDidChange")

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

    static let logger = Logger(
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

    private(set) var deferredOwners: [UUID: Int32] = [:]
    private(set) var activationEpoch: UInt64?
    private(set) var claimedWindowIDs: Set<UUID> = []
    private var retiredAcknowledged = Set<UUID>()

    var isPassive: Bool { !deferredOwners.isEmpty }
    var mayApplyOnBoot: Bool { gate.shouldApplyOnBoot }

    private let isActive: () -> Bool
    private let isLiveInstance: @Sendable (Int32) -> Bool
    private let otherInstanceRunningProvider: () -> Bool
    private let scheduleAfter: MainScheduler
    private let uptime: @Sendable () -> UInt64
    private let workspaceNotificationCenter: NotificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastPublishedReopenableWindowIDs: [UUID] = []

    static let restoreAttemptSettleDelay: TimeInterval = 2.0
    private(set) var restoreAttemptsUnavailable = false
    private(set) var restoreAttemptStarts = 0
    private(set) var dormantWindowIDs: [UUID] = []

    init(
        repository: SessionSnapshotRepository,
        gate: SessionPersistenceGate,
        registry: PendingHydrationRegistry,
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        queue: DispatchQueue = DispatchQueue(label: "kr.co.devch.chostty.session-persistence", qos: .utility),
        isActive: @escaping () -> Bool = { NSApp.isActive },
        isLiveInstance: @escaping @Sendable (Int32) -> Bool = SessionPersistenceController.isLiveAppInstance,
        otherInstanceRunning: @escaping () -> Bool = SessionPersistenceController.anotherAppInstanceIsRunning,
        scheduleAfter: @escaping MainScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        controllersProvider: @escaping () -> [TerminalController] = { TerminalController.open }
    ) {
        self.repository = repository
        self.gate = gate
        self.registry = registry
        self.ownerInstanceID = ownerInstanceID
        self.ownerPID = ownerPID
        self.queue = queue
        self.isActive = isActive
        self.isLiveInstance = isLiveInstance
        self.otherInstanceRunningProvider = otherInstanceRunning
        self.scheduleAfter = scheduleAfter
        self.uptime = uptime
        self.workspaceNotificationCenter = workspaceNotificationCenter
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
        guard gate.shouldPersist else { return ([], []) }
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
        workspaceObservers.forEach {
            workspaceNotificationCenter.removeObserver($0)
        }
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
        observeWorkspaceLifecycle()
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

    static func anotherAppInstanceIsRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != ownPID && !$0.isTerminated }
    }

    func otherInstanceRunning() -> Bool {
        otherInstanceRunningProvider()
    }

    private func observeWorkspaceLifecycle() {
        guard workspaceObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        workspaceObservers = names.map { name in
            workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          application.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
                    self.refreshDormantWindows()
                }
            }
        }
    }

    /// Records a live owner when an inactive launch must defer its first write.
    @discardableResult
    func adoptOwnership(of stored: AppSessionSnapshot?) -> Bool {
        guard !isActive(),
              let stored else { return false }
        let owner = SessionSnapshotRepository.StoredOwner(
            ownerInstanceID: stored.ownerInstanceID,
            ownerPID: stored.ownerPID
        )
        guard owner.ownerInstanceID != ownerInstanceID,
              isLiveInstance(owner.ownerPID) else { return false }
        deferredOwners[owner.ownerInstanceID] = owner.ownerPID
        return true
    }

    func noteActivation() {
        guard isActive() else { return }
        let epoch = uptime()
        activationEpoch = epoch
        let previousOwners = deferredOwners
        deferredOwners.removeAll()
        saveState.forgetCompletedSaves()
        Self.logger.notice(
            "session.persist.claimed epoch=\(epoch, privacy: .public) previousOwners=\(previousOwners.count, privacy: .public)"
        )
        scheduleSave()
    }

    func noteLive(_ ids: Set<UUID>) {
        claimedWindowIDs.formUnion(ids)
        dormantWindowIDs.removeAll { ids.contains($0) }
        postDormantWindowsDidChange()
    }

    func claimDormant(_ id: UUID) {
        noteLive([id])
    }

    func storeDormant(_ ids: [UUID]) {
        dormantWindowIDs = ids.filter { !claimedWindowIDs.contains($0) }
        postDormantWindowsDidChange()
    }

    var reopenableWindowIDs: [UUID] {
        otherInstanceRunning() ? [] : dormantWindowIDs
    }

    var dockReopenCandidateIDs: [UUID] {
        let quarantined = restoreQuarantine().windows
        return reopenableWindowIDs.filter { !quarantined.contains($0) }
    }

    func refreshDormantWindows() {
        switch repository.load() {
        case .loaded(let snapshot, _):
            storeDormant(snapshot.windows.map(\.physicalUUID))
        case .absent, .unusable:
            storeDormant([])
        }
    }

    func adoptStoredSession(
        liveWindowIDs: Set<UUID>
    ) -> (snapshot: AppSessionSnapshot, source: SessionSnapshotRepository.Source)? {
        guard gate.shouldPersist else { return nil }
        switch repository.load() {
        case .absent:
            Self.logger.notice("session.restore.skipped reason=noSnapshot")
            return nil
        case .unusable(let reason):
            Self.logger.warning("session.restore.skipped reason=unusable detail=\(reason, privacy: .public)")
            return nil
        case .loaded(let snapshot, let source):
            _ = adoptOwnership(of: snapshot)
            let ids = Set(snapshot.windows.flatMap { window in
                [window.physicalUUID] + window.workspaces.flatMap(\.tabs).map(\.id)
            })
            pruneRestoreAttempts(keeping: ids)
            noteLive(liveWindowIDs)
            storeDormant(snapshot.windows.map(\.physicalUUID))
            return (snapshot, source)
        }
    }

    func storedWindows(matching ids: Set<UUID>) -> [WindowSnapshot] {
        guard case .loaded(let snapshot, _) = repository.load() else { return [] }
        return snapshot.windows.filter {
            ids.contains($0.physicalUUID) && !claimedWindowIDs.contains($0.physicalUUID)
        }
    }

    enum KeepDormantReason: Equatable {
        case explicitOpenIntent
        case anotherInstanceRunning
        case windowAlreadyOpen
        case initialWindowDisabled
        case quarantined
    }

    struct BootDecision: Equatable {
        var apply: [WindowSnapshot]
        var keepDormant: [WindowSnapshot]
        var reason: KeepDormantReason?
    }

    static func bootDecision(
        windows: [WindowSnapshot],
        quarantinedWindows: Set<UUID>,
        mayApplyOnBoot: Bool,
        anotherInstanceRunning: Bool,
        hasOpenWindow: Bool,
        initialWindow: Bool
    ) -> BootDecision {
        if !mayApplyOnBoot {
            return BootDecision(apply: [], keepDormant: windows, reason: .explicitOpenIntent)
        }
        if anotherInstanceRunning {
            return BootDecision(apply: [], keepDormant: windows, reason: .anotherInstanceRunning)
        }
        if hasOpenWindow {
            return BootDecision(apply: [], keepDormant: windows, reason: .windowAlreadyOpen)
        }
        if !initialWindow {
            return BootDecision(apply: [], keepDormant: windows, reason: .initialWindowDisabled)
        }
        let quarantined = windows.filter { quarantinedWindows.contains($0.physicalUUID) }
        let apply = windows.filter { !quarantinedWindows.contains($0.physicalUUID) }
        return BootDecision(
            apply: apply,
            keepDormant: quarantined,
            reason: quarantined.isEmpty ? nil : .quarantined
        )
    }

    private func postDormantWindowsDidChange() {
        let current = reopenableWindowIDs
        guard lastPublishedReopenableWindowIDs != current else { return }
        lastPublishedReopenableWindowIDs = current
        NotificationCenter.default.post(name: Self.dormantWindowsDidChange, object: self)
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

        enum SynchronizationAvailability: Equatable {
            case available
            case persistenceDisabled
            case noLiveState
        }

        let current: AppSessionSnapshot?
        let saved: AppSessionSnapshot?
        let status: Status
        let synchronizationAvailability: SynchronizationAvailability
        let reopenableWindowCount: Int
        let heldBackWindowCount: Int
        let heldBackTabCount: Int
        let anotherInstanceRunning: Bool

        var canSynchronize: Bool {
            synchronizationAvailability == .available
        }
    }

    /// Inspects the live projection and the repository's validated snapshot.
    /// Owner fields intentionally do not participate in this comparison: they
    /// describe the writer, not the workspace graph the sidebar displays.
    func sidebarSyncInspection() -> SidebarSyncInspection {
        let controllers = controllersProvider()
        let live = controllers.isEmpty ? nil : snapshot(from: controllers)
        let quarantine = restoreQuarantine()
        let anotherInstanceRunning = otherInstanceRunning()
        let reopenableWindowCount = anotherInstanceRunning ? 0 : dormantWindowIDs.count
        let availability = synchronizationAvailability(hasLiveState: live != nil)

        switch repository.load() {
        case .absent:
            return SidebarSyncInspection(
                current: live,
                saved: nil,
                status: live == nil ? .liveStateUnavailable : .absent,
                synchronizationAvailability: availability,
                reopenableWindowCount: reopenableWindowCount,
                heldBackWindowCount: 0,
                heldBackTabCount: 0,
                anotherInstanceRunning: anotherInstanceRunning
            )

        case .loaded(let saved, _):
            let current = live.map {
                AppSessionSnapshot(
                    ownerInstanceID: $0.ownerInstanceID,
                    ownerPID: $0.ownerPID,
                    windows: ($0.windows + saved.windows.filter {
                        !claimedWindowIDs.contains($0.physicalUUID)
                    }).sorted { $0.physicalUUID.uuidString < $1.physicalUUID.uuidString }
                )
            }
            let savedWindowIDs = Set(saved.windows.map(\.physicalUUID))
            let savedTabIDs = Set(saved.windows.flatMap(\.workspaces).flatMap(\.tabs).map(\.id))
            guard let current else {
                return SidebarSyncInspection(
                    current: nil,
                    saved: saved,
                    status: .liveStateUnavailable,
                    synchronizationAvailability: availability,
                    reopenableWindowCount: reopenableWindowCount,
                    heldBackWindowCount: quarantine.windows.intersection(savedWindowIDs).count,
                    heldBackTabCount: quarantine.tabs.intersection(savedTabIDs).count,
                    anotherInstanceRunning: anotherInstanceRunning
                )
            }
            return SidebarSyncInspection(
                current: current,
                saved: saved,
                status: current.windows == saved.windows ? .synchronized : .outOfSync,
                synchronizationAvailability: availability,
                reopenableWindowCount: reopenableWindowCount,
                heldBackWindowCount: quarantine.windows.intersection(savedWindowIDs).count,
                heldBackTabCount: quarantine.tabs.intersection(savedTabIDs).count,
                anotherInstanceRunning: anotherInstanceRunning
            )

        case .unusable(let reason):
            return SidebarSyncInspection(
                current: live,
                saved: nil,
                status: live == nil ? .liveStateUnavailable : .unusable(reason),
                synchronizationAvailability: availability,
                reopenableWindowCount: reopenableWindowCount,
                heldBackWindowCount: 0,
                heldBackTabCount: 0,
                anotherInstanceRunning: anotherInstanceRunning
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
        guard gate.shouldPersist else { return false }

        let controllers = controllersProvider()
        let live = Set(controllers.map(\.physicalUUID))
        noteLive(live)
        let retire = claimedWindowIDs.subtracting(live)

        if isPassive && !isActive() {
            let unacknowledged = retire.subtracting(retiredAcknowledged)
            guard !unacknowledged.isEmpty else { return false }
            write(
                nil,
                cursor: nil,
                retire: unacknowledged,
                synchronously: false
            )
            return true
        }

        let cursor = saveCursor(from: controllers)
        guard saveState.reserve(cursor) else { return false }
        write(
            snapshot(from: controllers),
            cursor: cursor,
            retire: retire,
            synchronously: false
        )
        return true
    }

    /// Blocks until the save attempt finishes. Invalid projections and I/O
    /// failures leave the previous valid snapshot in place.
    func persistNow() {
        guard !isTerminating else { return }
        guard gate.shouldPersist else { return }
        let controllers = controllersProvider()
        let live = Set(controllers.map(\.physicalUUID))
        noteLive(live)
        let retire = claimedWindowIDs.subtracting(live)
        if isPassive && !isActive() {
            let unacknowledged = retire.subtracting(retiredAcknowledged)
            guard !unacknowledged.isEmpty else { return }
            write(nil, cursor: nil, retire: unacknowledged, synchronously: true)
        } else {
            write(
                snapshot(from: controllers),
                cursor: saveCursor(from: controllers),
                retire: retire,
                synchronously: true
            )
        }
    }

    /// For tests; production does not need it, since the terminate path is
    /// synchronous.
    func flush() {
        queue.sync {}
    }

    private func write(
        _ snapshot: AppSessionSnapshot?,
        cursor: SaveCursor?,
        retire: Set<UUID>,
        synchronously: Bool
    ) {
        let repository = self.repository
        let saveState = self.saveState
        let enqueuedActivationEpoch = activationEpoch
        let policy = SessionSnapshotRepository.SavePolicy(
            claimEpoch: isActive() ? activationEpoch : nil,
            selfInstanceID: ownerInstanceID,
            selfPID: ownerPID,
            deferredOwnerIDs: Set(deferredOwners.keys),
            isLiveInstance: isLiveInstance,
            now: uptime,
            retire: retire,
            preserveStoredWindowsExcept: claimedWindowIDs
        )
        let work = { () -> SessionSnapshotRepository.SaveReceipt? in
            do {
                let receipt = try repository.save(snapshot, policy: policy)
                if let cursor {
                    switch receipt.outcome {
                    case .written, .skippedIdentical:
                        saveState.finish(cursor, result: .saved)
                    case .refusedInvalid(let rejection):
                        saveState.finish(cursor, result: .rejected(rejection))
                    case .yielded:
                        saveState.finish(cursor, result: .yielded)
                    case .retired:
                        // The cursor stays unsaved so the next write records the yield.
                        saveState.finish(cursor, result: .failed)
                    case .nothingToWrite:
                        saveState.finish(cursor, result: .saved)
                    }
                }
                return receipt
            } catch {
                // A failed write is retried on the next tick; the previous file
                // is still on disk and still usable.
                Self.logger.warning("session.persist.writeFailed \(String(describing: error), privacy: .public)")
                if let cursor {
                    saveState.finish(cursor, result: .failed)
                }
            }
            return nil
        }

        if synchronously {
            applySaveResult(
                queue.sync(execute: work),
                retire: retire,
                enqueuedActivationEpoch: enqueuedActivationEpoch
            )
        } else {
            queue.async { [weak self] in
                let receipt = work()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.applySaveResult(
                            receipt,
                            retire: retire,
                            enqueuedActivationEpoch: enqueuedActivationEpoch
                        )
                    }
                }
            }
        }
    }

    private func applySaveResult(
        _ receipt: SessionSnapshotRepository.SaveReceipt?,
        retire: Set<UUID>,
        enqueuedActivationEpoch: UInt64?
    ) {
        guard let receipt else {
            applySaveResult(.failed)
            return
        }
        switch receipt.outcome {
        case .yielded(let owner):
            retiredAcknowledged.formUnion(retire.subtracting(receipt.remainingRetireWindowIDs))
            if enqueuedActivationEpoch == activationEpoch {
                deferredOwners[owner.ownerInstanceID] = owner.ownerPID
                Self.logger.notice(
                    "session.persist.yielded owner=\(owner.ownerInstanceID.uuidString, privacy: .public) pid=\(owner.ownerPID, privacy: .public)"
                )
            }
            applySaveResult(.yielded)
        case .retired:
            retiredAcknowledged.formUnion(retire.subtracting(receipt.remainingRetireWindowIDs))
            // The health maps to `.saved` because the write succeeded.
            applySaveResult(.saved)
        case .written, .skippedIdentical:
            storeDormant(receipt.preservedWindowIDs)
            applySaveResult(.saved)
        case .refusedInvalid(let rejection):
            applySaveResult(.rejected(rejection))
        case .nothingToWrite:
            applySaveResult(.saved)
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
        noteLive(Set(controllers.map(\.physicalUUID)))
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
