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
/// When neither counter moved and the window set is unchanged, a tick does no
/// projection at all.
@MainActor
final class SessionPersistenceController {
    /// Also the upper bound on what a crash or SIGKILL can lose. An ordinary
    /// quit loses nothing, because `applicationWillTerminate` saves
    /// synchronously.
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
    /// same file.
    private let queue = DispatchQueue(label: "com.chostty.session-persistence", qos: .utility)

    private var timer: Timer?
    private var lastMountGenerations: [UUID: UInt64] = [:]
    private var lastMetadataGenerations: [UUID: UInt64] = [:]
    private var lastWindowIDs: Set<UUID> = []
    private var hasProjectedOnce = false

    /// Set when boot found another live instance owning the file.
    private(set) var isDisabledBySecondInstance = false

    init(
        repository: SessionSnapshotRepository,
        gate: SessionPersistenceGate,
        registry: PendingHydrationRegistry,
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        controllersProvider: @escaping () -> [TerminalController] = { TerminalController.all }
    ) {
        self.repository = repository
        self.gate = gate
        self.registry = registry
        self.ownerInstanceID = ownerInstanceID
        self.ownerPID = ownerPID
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

    func disableForSecondInstance() {
        isDisabledBySecondInstance = true
        stop()
        Self.logger.notice("session.persist.disabledSecondInstance")
    }

    /// `kill(pid, 0)` sends no signal, only the existence and permission
    /// checks. `EPERM` means the process exists but belongs to another user,
    /// which still counts as alive; only `ESRCH` is dead. The app is not
    /// sandboxed, so this is not blocked.
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Decides, once at boot, whether another live instance owns the file.
    ///
    /// Both conditions are required. An instance-id mismatch alone is true on
    /// every ordinary relaunch, since a new id is issued per process and the
    /// previous run always saves on quit; keying off it would switch
    /// persistence off from the second launch onward and freeze the user's
    /// layout at whatever the first run wrote.
    @discardableResult
    func adoptOwnership(
        of stored: AppSessionSnapshot?,
        isProcessAlive: (Int32) -> Bool = SessionPersistenceController.processIsAlive
    ) -> Bool {
        guard let stored else { return false }
        guard stored.ownerInstanceID != ownerInstanceID else { return false }
        guard isProcessAlive(stored.ownerPID) else { return false }

        disableForSecondInstance()
        return true
    }

    // MARK: - Saving

    /// - Returns: `true` when a projection ran. The write itself may still be
    ///   skipped because the bytes matched.
    @discardableResult
    func persistIfNeeded() -> Bool {
        guard canPersist else { return false }

        let controllers = controllersProvider()
        guard hasChanges(controllers) else { return false }

        write(snapshot(from: controllers), synchronously: false)
        return true
    }

    /// Blocks until the bytes are on disk. `applicationWillTerminate` has to
    /// finish before it returns, and the snapshot is a few UUIDs and path
    /// strings.
    func persistNow() {
        guard canPersist else { return }
        write(snapshot(from: controllersProvider()), synchronously: true)
    }

    /// For tests; production does not need it, since the terminate path is
    /// synchronous.
    func flush() {
        queue.sync {}
    }

    private var canPersist: Bool {
        gate.shouldPersist && !isDisabledBySecondInstance
    }

    private func write(_ snapshot: AppSessionSnapshot, synchronously: Bool) {
        let repository = self.repository
        let work = {
            do {
                _ = try repository.save(snapshot)
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

    private func hasChanges(_ controllers: [TerminalController]) -> Bool {
        var changed = false

        let windowIDs = Set(controllers.map(\.physicalUUID))
        if windowIDs != lastWindowIDs {
            lastWindowIDs = windowIDs
            changed = true
        }

        var mountGenerations: [UUID: UInt64] = [:]
        var metadataGenerations: [UUID: UInt64] = [:]
        for controller in controllers {
            let store = controller.workspaceStore
            mountGenerations[controller.physicalUUID] = store.snapshot.mountGeneration
            for session in store.allSessions {
                metadataGenerations[session.id] = session.metadataGeneration
            }
        }

        if mountGenerations != lastMountGenerations {
            lastMountGenerations = mountGenerations
            changed = true
        }
        if metadataGenerations != lastMetadataGenerations {
            lastMetadataGenerations = metadataGenerations
            changed = true
        }

        // The first tick always projects: this process has a fresh owner id,
        // so the file has to record who owns it now.
        if !hasProjectedOnce {
            hasProjectedOnce = true
            changed = true
        }

        return changed
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
