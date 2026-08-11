import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A base class for windows that can contain Ghostty windows. This base class implements
/// the bare minimum functionality that every terminal window in Ghostty should implement.
///
/// Usage: Specify this as the base class of your window controller for the window that contains
/// a terminal. The window controller must also be the window delegate OR the window delegate
/// functions on this base class must be called by your own custom delegate. For the terminal
/// view the TerminalView SwiftUI view must be used and this class is the view model and
/// delegate.
///
/// Special considerations to implement:
///
///   - Fullscreen: you must manually listen for the right notification and implement the
///   callback that calls toggleFullscreen on this base class.
///
/// Notably, things this class does NOT implement (not exhaustive):
///
///   - Tabbing, because there are many ways to get tabbed behavior in macOS and we
///   don't want to be opinionated about it.
///   - Window restoration or save state
///   - Window visual styles (such as titlebar colors)
///
/// The primary idea of all the behaviors we don't implement here are that subclasses may not
/// want these behaviors.
class BaseTerminalController: NSWindowController,
                              NSWindowDelegate,
                              TerminalViewDelegate,
                              TerminalViewModel,
                              ClipboardConfirmationViewDelegate,
                              FullscreenDelegate {
    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App

    /// Stable, unique identifier for this physical controller/window. This
    /// UUID identifies the physical owner for the lifetime
    /// of the controller and is the value surfaced to accessibility, undo, and
    /// (in later phases) the owner registry.
    let physicalUUID: UUID

    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? {
        didSet { syncFocusToSurfaceTree() }
    }

    /// The tree of splits within this terminal window.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    /// This controller's nonoptional workspace store.
    ///
    /// The store is constructed up-front by ``TerminalControllerGraphFactory``
    /// and injected via the designated `init(_:graph:)` initializer. There is
    /// no optional, lazy, IUO, or empty-bootstrap seam: a controller cannot
    /// exist without a fully initialized store and committed initial snapshot.
    let workspaceStore: WorkspaceSessionStore
    var filesPanelController: FilesPanelController? { nil }

    /// The session ID last **successfully presented** (mounted) on this
    /// controller. Distinct from the store's desired selection: a desired
    /// selection change does not update this until the corresponding mount
    /// succeeds at the current generation.
    private(set) var presentedSessionID: UUID?

    /// The ``WorkspaceSessionStore/mountGeneration`` of the snapshot most
    /// recently presented on this controller. Mounting compares the candidate
    /// generation to this value and only re-mounts when strictly newer.
    private(set) var presentedMountGeneration: UInt64 = 0
    /// Per-controller bounded history of destructively-closed tabs. The
    /// SOLE authority for `reopenClosedTab()` — never consult `undoManager`
    /// for "what did I just close", since that stack is process-wide and
    /// shared with New Window/New Tab/Move Split/Close Other Tabs/Close Tabs
    /// to the Right.
    let closedTabHistory = ClosedTabHistory()

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false

    /// Set if the terminal view should show the update overlay.
    @Published var updateOverlayIsVisible: Bool = false

    /// True when any surface in this controller currently has an active bell.
    @Published private(set) var bell: Bool = false

    /// Where this window renders the workspace controls (sidebar toggle, new
    /// workspace, workspace actions).
    ///
    /// Recomputed on every fullscreen transition, which is the moment a window
    /// gains or loses a titlebar that can host them. Base default is
    /// `.sidebarHeader`; see `computeWorkspaceControlsPlacement()`.
    @Published private(set) var workspaceControlsPlacement: WorkspaceControlsPlacement = .sidebarHeader

    /// Mirrors `window.title` for the `.contentStrip` placement, which draws the
    /// title itself because the system title is hidden or gone in every case
    /// that selects it.
    @Published private(set) var windowTitle: String = ""

    /// Mirrors `window.representedURL` for the same reason: the strip draws the
    /// proxy icon that the hidden titlebar would have shown.
    @Published private(set) var windowRepresentedURL: URL?

    /// Whether the terminal surface should focus when the mouse is over it.
    var focusFollowsMouse: Bool {
        self.derivedConfig.focusFollowsMouse
    }

    /// Non-nil when an alert is active so we don't overlap multiple.
    private var alert: NSAlert?

    /// The clipboard confirmation window, if shown.
    private var clipboardConfirmation: ClipboardConfirmationController?

    /// Fullscreen state management.
    private(set) var fullscreenStyle: FullscreenStyle?

    /// Event monitor (see individual events for why)
    private var eventMonitor: Any?

    /// The previous frame information from the window
    private var savedFrame: SavedFrame?

    /// Cache previously applied appearance to avoid unnecessary updates
    private var appliedColorScheme: ghostty_color_scheme_e?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Track whether background is forced opaque (true) or using config transparency (false)
    var isBackgroundOpaque: Bool = false

    private var focusedSurfaceCancellables: Set<AnyCancellable> = []

    /// Per-session metadata subscriptions, keyed by session id.
    ///
    /// `focusedSurfaceCancellables` only watches the *presented* tab, so on its
    /// own a background tab's title/pwd/bell would freeze at whatever it was
    /// when the user last left it. The sidebar and tab bar show every tab, so
    /// each session needs its own subscription regardless of what is mounted.
    private var sessionMetadataCancellables: [UUID: Set<AnyCancellable>] = [:]

    /// Rebuilds the per-session subscriptions when the roster changes.
    private var sessionRosterCancellable: AnyCancellable?

    /// Cancellable for aggregating bell state across all surfaces in this controller.
    private var bellStateCancellable: AnyCancellable?

    /// An override title for the tab/window set by the user via prompt_tab_title.
    /// When set, this takes precedence over the computed title from the terminal.
    var titleOverride: String? {
        didSet { applyTitleToWindow() }
    }

    /// The last computed title from the focused surface (without the override).
    private var lastComputedTitle: String = "👻"

    /// The time that undo/redo operations that contain running ptys are valid for.
    var undoExpiration: Duration {
        ghostty.config.undoTimeout
    }

    /// The undo manager for this controller is the undo manager of the window,
    /// which we set via the delegate method.
    override var undoManager: ExpiringUndoManager? {
        // This should be set via the delegate method windowWillReturnUndoManager
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        // If the window one isn't set, we fallback to our global one.
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            return appDelegate.undoManager
        }

        return nil
    }

    struct SavedFrame {
        let window: NSRect
        let screen: NSRect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// Designated initializer. The controller receives a
    /// fully initialized ``TerminalControllerGraphFactory.InitialGraph``
    /// containing a nonoptional store with a committed initial snapshot, the
    /// initial session, and the surface tree to present.
    ///
    /// Subclasses must build the graph via ``TerminalControllerGraphFactory``
    /// before delegating. No surface, session, or store is created here; only
    /// observation/telemetry setup happens after `super.init`.
    /// `restoredPhysicalUUID` rehydrates the identity persisted by a prior
    /// run. AppleScript derives a window's `id` from this, so minting a fresh
    /// one on restore silently invalidates every saved reference: a script
    /// that stored an id before quit would address nothing after relaunch.
    /// Pass nil for a genuinely new window.
    init(_ ghostty: Ghostty.App,
         graph: TerminalControllerGraphFactory.InitialGraph,
         restoredPhysicalUUID: UUID? = nil
    ) {
        self.ghostty = ghostty
        self.physicalUUID = restoredPhysicalUUID ?? UUID()
        self.derivedConfig = DerivedConfig(ghostty.config)
        self.workspaceStore = graph.store

        super.init(window: nil)

        // Mount the initial presentation. didSet on `surfaceTree`/`focusedSurface`
        // fires once each; `surfaceTreeDidChange` runs but no notification observers
        // are registered yet, so there is no re-entrancy.
        self.surfaceTree = graph.initialSurfaceTree
        self.focusedSurface = graph.focusedSurface

        // Record the initial presentation as already mounted at the store's
        // committed generation. The first user-driven change bumps the store's
        // generation strictly past this value.
        self.presentedSessionID = graph.initialSession.id
        self.presentedMountGeneration = graph.store.snapshot.mountGeneration

        // Register initial surfaces, then install the pre-commit hook so every
        // subsequent structural transaction replaces the registry index before
        // the store publishes its new snapshot.
        syncRegistryToSnapshot()
        self.workspaceStore.willCommit = { [weak self] workspaces, _ in
            self?.replaceRegistryIndex(for: workspaces)
        }

        // Subscribe every session to its own surface metadata, and re-subscribe
        // whenever the roster changes, so a newly created or background tab
        // reports title/pwd/bell without needing to be mounted first.
        rebuildSessionMetadataSubscriptions()
        sessionRosterCancellable = self.workspaceStore.$snapshot
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildSessionMetadataSubscriptions()

                // Any structural or selection change alters what would be
                // persisted, so tell AppKit the saved state is stale. Without
                // this, adding or switching a workspace/tab never triggers a
                // re-save and a relaunch restores whatever the last split
                // change happened to leave behind.
                self.invalidateRestorableState()
            }

        // Setup our bell state for the window
        setupBellNotificationPublisher()

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onConfirmClipboardRequest),
            name: Ghostty.Notification.confirmClipboard,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(didChangeScreenParametersNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChangeBase(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyCommandPaletteDidToggle(_:)),
            name: .ghosttyCommandPaletteDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyMaximizeDidToggle(_:)),
            name: .ghosttyMaximizeDidToggle,
            object: nil)

        // Splits
        center.addObserver(
            self,
            selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidToggleSplitZoom(_:)),
            name: Ghostty.Notification.didToggleSplitZoom,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidResizeSplit(_:)),
            name: Ghostty.Notification.didResizeSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidPresentTerminal(_:)),
            name: Ghostty.Notification.ghosttyPresentTerminal,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttySurfaceDragEndedNoTarget(_:)),
            name: .ghosttySurfaceDragEndedNoTarget,
            object: nil)

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }
    }

    /// Convenience initializer that builds the graph via
    /// ``TerminalControllerGraphFactory`` before delegating to the designated
    /// initializer. Provided for call sites that still construct a controller
    /// from an optional base config and/or an existing surface tree.
    convenience init(_ ghostty: Ghostty.App,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) {
        let graph: TerminalControllerGraphFactory.InitialGraph
        if let tree {
            graph = TerminalControllerGraphFactory.makeFromTree(ghostty: ghostty, tree: tree)
        } else {
            graph = TerminalControllerGraphFactory.makeOrdinary(ghostty: ghostty, baseConfig: base)
        }
        self.init(ghostty, graph: graph)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }


    // MARK: Virtual workspace support

    /// Selects a workspace/tab by (workspaceID, tabID). The desired selection is
    /// applied through the store's stage→commit transaction (one snapshot
    /// publication, generation bumped). The presented surfaceTree is swapped
    /// only when the committed candidate generation strictly exceeds the
    /// previously presented generation.
    ///
    /// This is the single entry point for changing which
    /// session is presented. The old session's tree is retained by the store
    /// so its PTY stays alive; the previously-presented session is unmounted.
    func selectSession(workspaceID: UUID, tabID: UUID) {
        let store = workspaceStore
        guard let session = store.session(forTabID: tabID) else { return }

        // Skip if already presenting this session at or beyond the candidate
        // generation — this guards against stale mounts and feedback loops.
        if presentedSessionID == tabID,
           store.snapshot.mountGeneration <= presentedMountGeneration {
            return
        }

        // Save the currently presented tree/focus back into the previously
        // presented session so re-selecting it restores exactly this state.
        if let currentID = presentedSessionID,
           let currentSession = store.session(forTabID: currentID) {
            currentSession.surfaceTree = surfaceTree
            currentSession.focusedSurfaceID = focusedSurface?.id
            currentSession.unmount()
        }

        // Commit the desired selection — but only when it is not already the
        // store's committed selection.
        //
        // `addTab`/`addWorkspace` already commit with the new tab selected, so
        // the caller's follow-up `selectSession` would otherwise publish a
        // second, topologically identical snapshot and bump the generation
        // twice for one user action, re-rendering every subscriber twice.
        if store.snapshot.selection != Selection(workspaceID: workspaceID, tabID: tabID) {
            let candidate = store.candidateSelecting(
                workspaceID: workspaceID, tabID: tabID)
            guard store.validate(candidate) else { return }
            store.commit(candidate)
        }

        // Mount only if the committed generation is strictly newer than what
        // this controller last presented. This is the compensation gate.
        guard store.snapshot.mountGeneration > presentedMountGeneration else { return }

        // Promote the incoming session to "presented" BEFORE swapping the tree.
        //
        // Assigning `surfaceTree` fires `didSet` → `surfaceTreeDidChange`, which
        // writes the presented tree back into `presentedSessionID`'s session. If
        // that still pointed at the OUTGOING tab, the swap would immediately
        // overwrite the outgoing session's tree with the incoming one — two
        // sessions sharing a tree, and the outgoing tab's SurfaceViews losing
        // their last strong reference (the registry holds UUIDs only), killing
        // its PTY. Promoting first makes that write-back land on the incoming
        // session, where it is an idempotent no-op.
        presentedSessionID = session.id
        presentedMountGeneration = store.snapshot.mountGeneration

        surfaceTree = session.surfaceTree
        focusedSurface = session.surfaceTree.first(where: { $0.id == session.focusedSurfaceID })
            ?? session.surfaceTree.first

        // Update window title from the selected session.
        titleDidChange(to: session.title)

        // Make the focused surface first responder on next run loop
        // (SwiftUI needs to re-render the new tree first).
        DispatchQueue.main.async { [weak self] in
            guard let self, let surface = self.focusedSurface else { return }
            self.window?.makeFirstResponder(surface)
        }
    }

    /// Replaces this controller's `SurfaceOwnerRegistry` index for a topology.
    ///
    /// Installed as the store's `willCommit` hook so it runs between validate
    /// and the single `@Published snapshot` assignment, satisfying the required
    /// stage → validate → registry → publish → mount order. Taking the topology
    /// as a parameter (rather than reading `workspaceStore.snapshot`) is what
    /// makes the pre-publication call possible.
    private func replaceRegistryIndex(for workspaces: [WorkspaceSession]) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let registry = appDelegate.surfaceOwners else { return }
        let controllerID = ObjectIdentifier(self)
        var locations: [SurfaceOwnerLocation] = []
        for ws in workspaces {
            for session in ws.tabs {
                for surface in session.surfaceTree {
                    locations.append(SurfaceOwnerLocation(
                        controllerID: controllerID,
                        workspaceID: ws.id,
                        tabID: session.id,
                        surfaceID: surface.id
                    ))
                }
            }
        }
        registry.replaceIndex(for: controllerID, locations: locations)
    }

    /// Syncs the registry from the currently committed snapshot.
    ///
    /// Used for topology changes that do not flow through `commit(_:)` — most
    /// importantly split create/close, which mutates the presented tree
    /// directly rather than through a structural candidate.
    func syncRegistryToSnapshot() {
        replaceRegistryIndex(for: workspaceStore.snapshot.workspaces)
    }

    /// Every live surface across every virtual tab in this physical window.
    ///
    /// `surfaceTree` is only the *presented* tab. Anything that reasons about
    /// the whole window — close/quit confirmation above all — must use this,
    /// because background virtual tabs hold live processes that are invisible
    /// to `surfaceTree`.
    var allWorkspaceSurfaces: [Ghostty.SurfaceView] {
        workspaceStore.snapshot.workspaces.flatMap { ws in
            ws.tabs.flatMap { session -> [Ghostty.SurfaceView] in
                // The presented session's authoritative tree lives on the
                // controller; the store's copy is only refreshed on write-back.
                session.id == presentedSessionID
                    ? Array(surfaceTree)
                    : Array(session.surfaceTree)
            }
        }
    }

    /// Creates a new virtual workspace with a fresh terminal surface.
    /// This does NOT create a new NSWindow.
    @discardableResult
    func newVirtualWorkspace(
        source: Ghostty.SurfaceView? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        origin: TerminalCommandRouter.ConfigOrigin = .explicit
    ) -> UUID? {
        let store = workspaceStore
        guard let ghostty_app = ghostty.app else { return nil }

        // Create a new surface for the new workspace, resolving its working
        // directory through the shared precedence: explicit baseConfig >
        // the currently-selected workspace's defaultDirectory > inherited
        // config > shell default.
        let config = TerminalCommandRouter.resolvedConfig(
            workspace: store.selectedWorkspace,
            source: source ?? focusedSurface,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            baseConfig: baseConfig,
            origin: origin)
        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
        let session = TerminalSessionState(id: UUID(), surfaceTree: newTree)

        // Save current tree back into the currently presented session so the
        // previous tab's state is preserved when we re-select it.
        if let currentID = presentedSessionID,
           let currentSession = store.session(forTabID: currentID) {
            currentSession.surfaceTree = surfaceTree
            currentSession.focusedSurfaceID = focusedSurface?.id
            currentSession.unmount()
        }

        // addWorkspace registers, stages, and commits the new topology in a
        // single snapshot publication.
        let wsID = store.addWorkspace(initialSession: session)

        // Promote first, then swap — same ordering requirement as
        // `selectSession`: the `surfaceTree` didSet write-back must land on the
        // incoming session, not the outgoing one.
        presentedSessionID = session.id
        presentedMountGeneration = store.snapshot.mountGeneration

        surfaceTree = newTree
        focusedSurface = newSurface

        return wsID
    }

    // MARK: Workspace/tab close (undo-backed)

    func closeWorkspaceTab(_ tabID: UUID) {
        _ = closeWorkspaceTab(tabID, historyRecording: true)
    }

    /// Closes a virtual tab, capturing its restore metadata and a
    /// `DetachedUndoLease` for both the ordinary `Cmd+Z` undo path and (unless
    /// `historyRecording` is false) a single ``ClosedTabHistory`` entry.
    ///
    /// `historyRecording` exists because of the grouped-undo defect: the
    /// multi-close paths (`closeOtherTabsImmediately`,
    /// `closeTabsOnTheRightImmediately`) call this N times inside one undo
    /// group. Recording N single entries there would let one grouped undo
    /// reverse all N closes while history still thinks only one tab came
    /// back, so the next reopen would duplicate a tab that is already back.
    /// Those callers pass `historyRecording: false` and instead push ONE
    /// group entry carrying all N returned leases.
    @discardableResult
    func closeWorkspaceTab(
        _ tabID: UUID,
        historyRecording: Bool
    ) -> (ClosedTabHistory.Record, DetachedUndoLease<TerminalSessionState>)? {
        let store = workspaceStore

        // Don't close if it's the only tab in the only workspace. This is a
        // GLOBAL `allSessions` count across every workspace in the store —
        // not this workspace's tab count — so the last tab standing anywhere
        // in the window can never be closed via this path even when other
        // workspaces are empty.
        let totalTabs = store.allSessions.count
        guard totalTabs > 1 else { return nil }

        // Capture restore coordinates before mutating: which workspace owned
        // this tab and at what index, so undo can put it back in place.
        guard let owningWorkspace = store.snapshot.workspaces.first(where: { ws in
            ws.tabs.contains(where: { $0.id == tabID })
        }) else { return nil }
        let restoreWorkspaceID = owningWorkspace.id
        let restoreWorkspaceName = owningWorkspace.name
        let restoreIndex = owningWorkspace.tabs.firstIndex(where: { $0.id == tabID })
        let presentedHit = presentedSessionID == tabID

        // Remove from store. The session stays in the live registry until we
        // explicitly unregister, so the removeTab transaction can still see it.
        guard let removedSession = store.removeTab(tabID) else { return nil }
        removedSession.readerStore.close()

        // If we were presenting this tab, switch to the new selection.
        if presentedHit {
            let sel = store.snapshot.selection
            if sel.tabID != tabID {
                selectSession(workspaceID: sel.workspaceID, tabID: sel.tabID)
            }
        }

        // Capture history metadata BEFORE the session is torn down. Deliberately
        // does NOT carry scrollback or process state — only what a fallback
        // reopen (fresh tab) can honestly restore.
        let record = ClosedTabHistory.Record(
            workspaceID: restoreWorkspaceID,
            workspaceName: restoreWorkspaceName,
            index: restoreIndex,
            title: removedSession.titleOverride ?? removedSession.title,
            titleOverride: removedSession.titleOverride,
            pwd: removedSession.pwd,
            tabColor: TerminalTabColor.fromStored(removedSession.tabColor)
        )

        // A destructive close takes exclusive ownership of the detached
        // session. The lease finalizes (tears down the PTY/surfaces) only if
        // undo never consumes it, so an undone close keeps the live process.
        //
        // Finalizing must also drop the session from the store's live registry.
        // Otherwise a closed-and-expired session lingers in `liveSessions`
        // forever and `validate(_:)` would still accept a candidate that
        // references the dead tab.
        let lease = DetachedUndoLease(payload: removedSession) { [weak store] session in
            session.tearDown()
            store?.unregister(session.id)
        }

        if historyRecording {
            closedTabHistory.recordSingle(record, lease: lease)
        }

        guard let undoManager else {
            // No undo support available: finalize immediately.
            lease.finalize()
            return (record, lease)
        }

        undoManager.setActionName("Close Tab")
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            // Consume the lease exactly once; a second undo is a no-op.
            guard let session = lease.consume() else { return }
            target.workspaceStore.register(session)
            target.workspaceStore.insertTab(
                session,
                intoWorkspace: restoreWorkspaceID,
                at: restoreIndex)
            let sel = target.workspaceStore.snapshot.selection
            target.selectSession(workspaceID: sel.workspaceID, tabID: sel.tabID)
        }

        return (record, lease)
    }

    func closeWorkspace(_ workspaceID: UUID) {
        _ = closeWorkspace(workspaceID, historyRecording: true)
    }

    /// Closes a virtual workspace, capturing per-tab restore metadata and
    /// leases for both the ordinary `Cmd+Z` undo path (which reassembles the
    /// whole workspace via `insertWorkspace`) and (unless `historyRecording`
    /// is false) ONE ``ClosedTabHistory`` group entry covering every detached
    /// session in tab order.
    @discardableResult
    func closeWorkspace(
        _ workspaceID: UUID,
        historyRecording: Bool
    ) -> [(ClosedTabHistory.Record, DetachedUndoLease<TerminalSessionState>)] {
        let store = workspaceStore

        // Don't close if it's the only workspace.
        guard store.snapshot.workspaces.count > 1 else { return [] }

        // Capture restore coordinates before mutating.
        //
        // This must include the presentation state, not just identity and
        // order: the workspace being restored already existed, so dropping its
        // directory, color or collapse choice would silently discard user
        // settings on Cmd+Z.
        guard let removed = store.snapshot.workspaces.first(where: { $0.id == workspaceID })
        else { return [] }
        let restoreIndex = store.snapshot.workspaces.firstIndex(where: { $0.id == workspaceID })
        let restoreName = removed.name
        let restoreSelectedTabID = removed.selectedTabID
        let restoreDefaultDirectory = removed.defaultDirectory
        let restoreColor = removed.color
        let restoreCollapsed = removed.isCollapsed
        let presentedHit = store.snapshot.selection.workspaceID == workspaceID

        // Remove from store.
        let removedSessions = store.removeWorkspace(workspaceID)
        guard !removedSessions.isEmpty else { return [] }
        removedSessions.forEach { $0.readerStore.close() }

        // If we were presenting a tab from this workspace, switch.
        if presentedHit {
            let sel = store.snapshot.selection
            selectSession(workspaceID: sel.workspaceID, tabID: sel.tabID)
        }

        // One lease PER TAB (not one combined array lease) so the SAME leases
        // back both the combined `Cmd+Z` restore below and the per-tab
        // ``ClosedTabHistory`` group entry. That sharing is what keeps the two
        // paths from disagreeing: if `Cmd+Z` already consumed every lease and
        // rebuilt the workspace, a later `reopenClosedTab()` correctly finds
        // them non-detached and falls back to fresh tabs instead of
        // duplicating the restored ones.
        let perTabLeases: [(TerminalSessionState, DetachedUndoLease<TerminalSessionState>)] =
            removedSessions.map { session in
                let lease = DetachedUndoLease(payload: session) { [weak store] session in
                    session.tearDown()
                    store?.unregister(session.id)
                }
                return (session, lease)
            }

        let pairs: [(ClosedTabHistory.Record, DetachedUndoLease<TerminalSessionState>)] =
            perTabLeases.enumerated().map { idx, pair in
                let (session, lease) = pair
                let record = ClosedTabHistory.Record(
                    workspaceID: workspaceID,
                    workspaceName: restoreName,
                    index: idx,
                    title: session.titleOverride ?? session.title,
                    titleOverride: session.titleOverride,
                    pwd: session.pwd,
                    tabColor: TerminalTabColor.fromStored(session.tabColor)
                )
                return (record, lease)
            }

        if historyRecording {
            closedTabHistory.recordGroup(pairs)
        }

        guard let undoManager else {
            for (_, lease) in perTabLeases { lease.finalize() }
            return pairs
        }

        undoManager.setActionName("Close Workspace")
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            // All-or-nothing: if any per-tab lease was already consumed or
            // finalized elsewhere, do not partially resurrect the workspace.
            var sessions: [TerminalSessionState] = []
            for (_, lease) in perTabLeases {
                guard let session = lease.consume() else { return }
                sessions.append(session)
            }
            guard !sessions.isEmpty else { return }
            for session in sessions {
                target.workspaceStore.register(session)
            }
            target.workspaceStore.insertWorkspace(
                id: workspaceID,
                name: restoreName,
                sessions: sessions,
                selectedTabID: restoreSelectedTabID,
                at: restoreIndex,
                defaultDirectory: restoreDefaultDirectory,
                color: restoreColor,
                isCollapsed: restoreCollapsed)
            let sel = target.workspaceStore.snapshot.selection
            target.selectSession(workspaceID: sel.workspaceID, tabID: sel.tabID)
        }

        return pairs
    }

    // Internal (not private) so ClosedTabHistory regression tests can
    // exercise the exact production close path directly, without depending
    // on `needsConfirmQuit` against a real spawned PTY (async confirmation
    // sheets never resolve synchronously in a headless test host).
    func closeOtherTabsImmediately(anchoredAt tabID: UUID? = nil) {
        guard let anchorID = tabID ?? presentedSessionID,
              let ws = workspaceStore.workspace(forTabID: anchorID) else { return }
        let others = ws.tabs.filter { $0.id != anchorID }
        guard !others.isEmpty else { return }

        // Start an undo grouping
        if let undoManager {
            undoManager.beginUndoGrouping()
        }
        defer {
            undoManager?.endUndoGrouping()
        }

        // Close every other virtual tab in this workspace, suppressing
        // per-tab history recording (see `closeWorkspaceTab`'s doc) and
        // collecting the returned (record, lease) pairs into ONE group entry.
        //
        // `closeWorkspaceTab` computes its record's `index` against `ws`'s
        // snapshot AT THE MOMENT of that call, which is already shifted by
        // every earlier removal in this loop. Normalize back to each tab's
        // ORIGINAL absolute index (captured before the loop starts) so
        // grouped reopen's ascending forward insertion reproduces the same
        // order Cmd+Z already gets for free from `NSUndoManager`'s LIFO
        // group replay.
        let originalIndices = Dictionary(
            uniqueKeysWithValues: ws.tabs.enumerated().map { ($0.element.id, $0.offset) })
        var groupPairs: [(ClosedTabHistory.Record, DetachedUndoLease<TerminalSessionState>)] = []
        for session in others {
            guard let pair = closeWorkspaceTab(session.id, historyRecording: false) else { continue }
            let (record, lease) = pair
            groupPairs.append((record.withIndex(originalIndices[session.id]), lease))
        }

        if !groupPairs.isEmpty {
            closedTabHistory.recordGroup(groupPairs)
        }

        if let undoManager {
            undoManager.setActionName("Close Other Tabs")
            // Load-bearing that this runs AFTER the loop above, not before:
            // each inner `closeWorkspaceTab` call sets the action name to
            // "Close Tab" (`BaseTerminalController.swift`). Hoisting this
            // `setActionName` before the loop would let that last inner call
            // silently overwrite it back to "Close Tab", mislabeling the
            // whole grouped undo.

            // We need to register an undo that refocuses this window. Otherwise, the
            // undo operation above for each tab will steal focus.
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    target.window?.makeKeyAndOrderFront(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeOtherTabsImmediately(anchoredAt: anchorID)
                }
            }
        }
    }

    // See `closeOtherTabsImmediately`'s doc for why this is not `private`.
    func closeTabsOnTheRightImmediately(anchoredAt tabID: UUID? = nil) {
        guard let anchorID = tabID ?? presentedSessionID,
              let ws = workspaceStore.workspace(forTabID: anchorID),
              let currentIndex = ws.tabs.firstIndex(where: { $0.id == anchorID }) else { return }

        let tabsToClose = ws.tabs.enumerated().filter { $0.offset > currentIndex }.map(\.element)
        guard !tabsToClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
        }

        // See `closeOtherTabsImmediately`'s matching comment: normalize each
        // record's `index` back to the ORIGINAL absolute index (captured
        // before this loop shifts anything), so grouped reopen replays in
        // the same order Cmd+Z's LIFO group undo already produces.
        let originalIndices = Dictionary(
            uniqueKeysWithValues: ws.tabs.enumerated().map { ($0.element.id, $0.offset) })
        var groupPairs: [(ClosedTabHistory.Record, DetachedUndoLease<TerminalSessionState>)] = []
        for session in tabsToClose {
            guard let pair = closeWorkspaceTab(session.id, historyRecording: false) else { continue }
            let (record, lease) = pair
            groupPairs.append((record.withIndex(originalIndices[session.id]), lease))
        }

        if !groupPairs.isEmpty {
            closedTabHistory.recordGroup(groupPairs)
        }

        if let undoManager {
            undoManager.setActionName("Close Tabs to the Right")
            // Load-bearing that this runs AFTER the loop above, not before:
            // each inner `closeWorkspaceTab` call sets the action name to
            // "Close Tab" (`BaseTerminalController.swift`). Hoisting this
            // `setActionName` before the loop would let that last inner call
            // silently overwrite it back to "Close Tab", mislabeling the
            // whole grouped undo.

            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    target.window?.makeKeyAndOrderFront(nil)
                }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeTabsOnTheRightImmediately(anchoredAt: anchorID)
                }
            }
        }
    }

    /// Closes every OTHER virtual tab in `tabID`'s workspace, prompting for
    /// confirmation if any of them has a process requiring it.
    ///
    /// Hoisted onto `BaseTerminalController` (not just `TerminalController`)
    /// so the view-model protocol can require it without an `as?` cast that
    /// silently no-ops for any other `TerminalViewModel` conformer (e.g.
    /// `QuickTerminalController`) that renders the same `TerminalView`.
    ///
    /// Reachable from two affordances sharing one predicate
    /// (`TerminalController.canCloseOtherTabs`): the "Close Other Tabs" menu
    /// command (anchored at the presented tab via `TerminalController`'s
    /// `@IBAction`) and the VirtualTabBar item's context menu (anchored at
    /// whichever tab was clicked, which need not be the presented one).
    func closeOtherTabs(fromTab tabID: UUID) {
        guard let ws = workspaceStore.workspace(forTabID: tabID) else { return }
        let others = ws.tabs.filter { $0.id != tabID }

        // If we only have one tab then we have no other tabs to close
        guard !others.isEmpty else { return }

        // Check if we have to confirm close. The anchor need not be the
        // PRESENTED tab (a context-menu close on a background tab), so the
        // presented tab itself can appear in `others` — its live surfaceTree
        // is `self.surfaceTree`, not the possibly-stale `session.surfaceTree`.
        let needsConfirm = others.contains { session in
            let tree = session.id == presentedSessionID ? surfaceTree : session.surfaceTree
            return tree.contains(where: { $0.needsConfirmQuit })
        }

        guard needsConfirm else {
            self.closeOtherTabsImmediately(anchoredAt: tabID)
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately(anchoredAt: tabID)
        }
    }

    /// Closes every virtual tab to the right of `tabID` in its workspace,
    /// prompting for confirmation if any of them has a process requiring it.
    /// See `closeOtherTabs(fromTab:)`'s doc for the two affordances this
    /// serves and why this lives on `BaseTerminalController`.
    func closeTabsOnTheRight(fromTab tabID: UUID) {
        guard let ws = workspaceStore.workspace(forTabID: tabID),
              let currentIndex = ws.tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let tabsToClose = ws.tabs.enumerated().filter { $0.offset > currentIndex }.map(\.element)
        guard !tabsToClose.isEmpty else { return }

        // See `closeOtherTabs(fromTab:)`'s matching comment: the anchor need
        // not be the presented tab, so the presented tab can appear here too.
        let needsConfirm = tabsToClose.contains { session in
            let tree = session.id == presentedSessionID ? surfaceTree : session.surfaceTree
            return tree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately(anchoredAt: tabID)
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately(anchoredAt: tabID)
        }
    }

    /// Reopens the most recently closed tab per ``ClosedTabHistory`` — the
    /// SOLE authority for what "closed most recently" means. NEVER a blind
    /// `undoManager.undo()`: that stack is process-wide and shared with New
    /// Window, New Tab, Move Split, Close Other Tabs and Close Tabs to the
    /// Right, so popping its top can un-split a pane instead of reopening a
    /// tab.
    ///
    /// Takes the fast path (restoring the original live session(s), same
    /// SurfaceView identities, same PTY) only when every lease in the entry is
    /// still detached. Otherwise every record in the entry falls back TOGETHER
    /// to a fresh tab restoring only working directory, title/override, color
    /// and the recorded index — never a partial/duplicated resurrection.
    ///
    /// Entries whose leases were CONSUMED are skipped entirely rather than
    /// falling back. A consumed lease means an ordinary `Cmd+Z` already took
    /// that session and put it back on screen, so the entry is spent; building
    /// fresh tabs from it would duplicate tabs the user is already looking at.
    /// That is what made close-other-tabs, `Cmd+Z`, then reopen produce five
    /// tabs where there should be three.
    /// Builds the surface configuration for a tab being recreated from
    /// recorded metadata.
    ///
    /// A recorded `pwd` is only applied if it still names a directory. The
    /// record can outlive the directory — a worktree removed, a build output
    /// cleaned, an external volume ejected — and unlike every other tab path
    /// this one had no such check, so it handed a dead path straight to a new
    /// surface while `TerminalCommandRouter` was carefully falling through for
    /// exactly the same condition.
    static func reopenConfig(for record: ClosedTabHistory.Record) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        if let pwd = record.pwd, TerminalCommandRouter.directoryExists(pwd) {
            config.workingDirectory = pwd
        }
        return config
    }

    func reopenClosedTab() {
        var popped: ClosedTabHistory.Entry?
        while let candidate = closedTabHistory.popNewest() {
            if candidate.leaseGroup.isSpent { continue }
            popped = candidate
            break
        }
        guard let entry = popped else { return }
        let store = workspaceStore

        func targetWorkspace(for record: ClosedTabHistory.Record) -> UUID {
            store.snapshot.workspaces.contains(where: { $0.id == record.workspaceID })
                ? record.workspaceID
                : store.snapshot.selection.workspaceID
        }

        var lastWorkspaceID: UUID?
        var lastTabID: UUID?

        if entry.leaseGroup.isAllDetached,
           let sessions = entry.leaseGroup.consumeAll(),
           sessions.count == entry.records.count {
            for (record, session) in zip(entry.records, sessions) {
                let wsID = targetWorkspace(for: record)
                store.insertTab(session, intoWorkspace: wsID, at: record.index)
                lastWorkspaceID = wsID
                lastTabID = session.id
            }
        } else {
            // Fallback: no resurrection. Finalize any lease still detached in
            // this entry so its PTY does not linger, then create fresh tabs
            // from the recorded metadata for every record together.
            entry.leaseGroup.finalizeAll()

            guard let ghosttyApp = ghostty.app else { return }

            for record in entry.records {
                let config = Self.reopenConfig(for: record)
                let newSurface = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
                let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
                let session = TerminalSessionState(id: UUID(), surfaceTree: newTree)
                session.titleOverride = record.titleOverride
                if record.tabColor != .none {
                    session.tabColor = String(record.tabColor.rawValue)
                }

                let wsID = targetWorkspace(for: record)
                store.insertTab(session, intoWorkspace: wsID, at: record.index)
                lastWorkspaceID = wsID
                lastTabID = session.id
            }
        }

        if let lastWorkspaceID, let lastTabID {
            selectSession(workspaceID: lastWorkspaceID, tabID: lastTabID)
        }
    }

    /// Duplicates a virtual tab. Reachable from a non-presented tab's
    /// context menu, so the config is built from the SOURCE tab's surface —
    /// never the controller's currently-focused surface.
    ///
    /// Order: `inheritedConfig` from the source session's focused surface (or
    /// its first surface) with the tab context, then override
    /// `workingDirectory` with the source's own LIVE `pwd`, then apply
    /// rung-1 precedence semantics via `TerminalCommandRouter.resolvedConfig` (the
    /// explicit override wins outright over the workspace default).
    ///
    /// Copies `pwd` and `titleOverride`. Does NOT copy scrollback or process
    /// state — the duplicate is a brand-new surface/PTY.
    ///
    /// Inserts immediately AFTER the source via `insertTab(_:intoWorkspace:at:)`
    /// (never `addTab`), so the duplicate lands right next to its source and
    /// becomes selected in the SOURCE workspace even when that workspace was
    /// not the selected one.
    @discardableResult
    func duplicateTab(_ tabID: UUID) -> UUID? {
        let store = workspaceStore
        guard let sourceWorkspace = store.workspace(forTabID: tabID),
              let sourceSession = store.session(forTabID: tabID),
              let sourceIndex = sourceWorkspace.tabs.firstIndex(where: { $0.id == tabID })
        else { return nil }
        guard let ghosttyApp = ghostty.app else { return nil }

        // Inherit from the SOURCE session's focused surface (or its first) —
        // not `focusedSurface`/`surfaceTree`, which describe whatever tab this
        // controller currently presents.
        let sourceTree = sourceSession.id == presentedSessionID ? surfaceTree : sourceSession.surfaceTree
        let inheritSource = sourceTree.first(where: { $0.id == sourceSession.focusedSurfaceID })
            ?? sourceTree.first

        var baseConfig: Ghostty.SurfaceConfiguration = inheritSource?.surface.map { surface in
            Ghostty.SurfaceConfiguration(
                from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
        } ?? Ghostty.SurfaceConfiguration()

        // Override with the source tab's own live pwd (not merely inherited),
        // since duplicate must copy the SPECIFIC tab being duplicated even
        // when it is not the focused/presented one.
        if let livePwd = sourceSession.pwd {
            baseConfig.workingDirectory = livePwd
        }

        let config = TerminalCommandRouter.resolvedConfig(
            workspace: sourceWorkspace,
            source: inheritSource,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: baseConfig,
            origin: .explicit)

        let newSurface = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
        let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
        let newSession = TerminalSessionState(id: UUID(), surfaceTree: newTree)
        newSession.titleOverride = sourceSession.titleOverride

        store.insertTab(newSession, intoWorkspace: sourceWorkspace.id, at: sourceIndex + 1)

        let sel = store.snapshot.selection
        selectSession(workspaceID: sel.workspaceID, tabID: sel.tabID)

        return newSession.id
    }


    /// Create a new split.
    @discardableResult
    func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        // We can only create new splits for surfaces in our tree.
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

        // Create a new surface view
        guard let ghostty_app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)

        // Do the split
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: oldView,
                direction: direction)
        } catch {
            // If splitting fails for any reason (it should not), then we just log
            // and return. The new view we created will be deinitialized and its
            // no big deal.
            Ghostty.logger.warning("failed to insert split: \(error, privacy: .public)")
            return nil
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: "New Split")

        return newView
    }

    /// Move focus to a surface view.
    func focusSurface(_ view: Ghostty.SurfaceView) {
        // Check if target surface is in our tree
        guard surfaceTree.contains(view) else { return }

        // Move focus to the target surface and activate the window/app
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
            view.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Called when the surfaceTree variable changed.
    ///
    /// Subclasses should call super first.
    func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        // If our surface tree becomes empty then we have no focused surface.
        if to.isEmpty {
            focusedSurface = nil
        }

        // Splits mutate the presented tree directly rather than through a
        // structural candidate, so the owning session and the owner registry
        // would otherwise never learn about surfaces a split created or
        // removed — leaving split-created surfaces unresolvable by source
        // lookup. Write the tree back and re-index here.
        if let presentedID = presentedSessionID,
           let session = workspaceStore.session(forTabID: presentedID) {
            session.surfaceTree = to

            // Only record focus that actually belongs to the tree being
            // presented. During a tab switch this runs while `focusedSurface`
            // still points at the OUTGOING tab's surface, so an unconditional
            // write would stamp a foreign surface ID onto the incoming
            // session — destroying its remembered pane (and any focus restored
            // from v8 state) before `selectSession` reads it back.
            if let focusedID = focusedSurface?.id,
               to.contains(where: { $0.id == focusedID }) {
                session.focusedSurfaceID = focusedID
            }
        }
        syncRegistryToSnapshot()

        syncSurfaceTreeOcclusionState()
    }

    /// Update all surfaces with the focus state. This ensures that libghostty has an accurate view about
    /// what surface is focused. This must be called whenever a surface OR window changes focus.
    func syncFocusToSurfaceTree() {
        for surfaceView in surfaceTree {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this view.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                surfaceView == focusedSurface &&
                surfaceView.isFirstResponder
            surfaceView.focusDidChange(focused)
        }
    }

    // Call this whenever the frame changes
    private func windowFrameDidChange() {
        // We need to update our saved frame information in case of monitor
        // changes (see didChangeScreenParameters notification).
        savedFrame = nil
        guard let window, let screen = window.screen else { return }
        savedFrame = .init(window: window.frame, screen: screen.visibleFrame)
    }

    func confirmCloseAsync(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close",
    ) async -> NSApplication.ModalResponse? {
        // If we already have an alert, we need to wait for that one.
        guard alert == nil else { return nil }

        // If there is no window to attach the modal then we assume success
        // since we'll never be able to show the modal.
        guard let window else {
            return .OK
        }

        // If multiple sessions in this window need confirmation, show one
        // confirmation for the whole window rather than one per session.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Store our alert so we only ever show one.
        self.alert = alert
        defer {
            // This is important so that we avoid losing focus when Stage
            // Manager is used (#8336)
            alert.window.orderOut(nil)
            self.alert = nil
        }
        return await alert.beginSheetModal(for: window)
    }

    func confirmClose(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close",
        completion: @escaping () -> Void
    ) {
        Task {
            guard let response = await confirmCloseAsync(messageText: messageText, informativeText: informativeText, confirmButtonTitle: confirmButtonTitle) else {
                completion()
                return
            }
            if [.alertFirstButtonReturn, .OK].contains(response) {
                completion()
            }
        }
    }

    /// Prompt the user to change the presented tab's title. Writes through
    /// `WorkspaceSessionStore.renameTab`, the same path the tab strip's and
    /// sidebar's "Rename…" context menu entries use, so the tab label (and
    /// the sidebar entry) actually changes — not just the window title, which
    /// is derived from `session.titleOverride` via `applyTitleToWindow`.
    func promptTabTitle() {
        guard let window else { return }
        guard let presentedSessionID else { return }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = workspaceStore.session(forTabID: presentedSessionID)?.titleOverride ?? window.title
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let newTitle = textField.stringValue
            self.workspaceStore.renameTab(presentedSessionID, to: newTitle)
            self.applyTitleToWindow()
        }
    }

    /// Close a surface from a view.
    func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let node = surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, withConfirmation: withConfirmation)
    }

    /// Close a surface node (which may contain splits), requesting confirmation if necessary.
    ///
    /// This will also insert the proper undo stack information in.
    func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // This node must be part of our tree
        guard surfaceTree.contains(node) else { return }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            removeSurfaceNode(node)
            return
        }

        // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
        // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
        // confirmationDialog allows the user to Cmd-W close the alert, but when doing
        // so SwiftUI does not update any of the bindings to note that window is no longer
        // being shown, and provides no callback to detect this.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            if let self {
                self.removeSurfaceNode(node)
            }
        }
    }

    // MARK: Split Tree Management

    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    private func findNextFocusTargetAfterClosing(node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        guard let root = surfaceTree.root else { return nil }

        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }

    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    private func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        // Move focus if the closed surface was focused and we have a next target
        let nextFocus: Ghostty.SurfaceView? = if node.contains(
            where: { $0 == focusedSurface }
        ) {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        replaceSurfaceTree(
            surfaceTree.removing(node),
            // When a non-focused surface is removed and this window stays as the key window,
            // we should refocus the `focusedSurface` to make sure the window's firstResponder remains as it is.
            //
            // This is a weird workaround, since `resignFirstResponder` wasn't called on `focusedSurface` after drag,
            // but the first responder became the window itself.
            moveFocusTo: nextFocus ?? focusedSurface,
            undoAction: "Close Terminal"
        )
    }

    func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // Setup our new split tree
        let oldTree = surfaceTree
        surfaceTree = newTree
        if let newView {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: newView, from: oldView)
            }
        }

        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if let oldView {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }

    // MARK: Notifications

    @objc private func didChangeScreenParametersNotification(_ notification: Notification) {
        // If we have a window that is visible and it is outside the bounds of the
        // screen then we clamp it back to within the screen.
        guard let window else { return }
        guard window.isVisible else { return }

        // We ignore fullscreen windows because macOS automatically resizes
        // those back to the fullscreen bounds.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let screen = window.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame

        // Clamp width/height
        if newFrame.size.width > visibleFrame.size.width {
            newFrame.size.width = visibleFrame.size.width
        }
        if newFrame.size.height > visibleFrame.size.height {
            newFrame.size.height = visibleFrame.size.height
        }

        // Ensure the window is on-screen. We only do this if the previous frame
        // was also on screen. If a user explicitly wanted their window off screen
        // then we let it stay that way.
        x: if newFrame.origin.x < visibleFrame.origin.x {
            if let savedFrame, savedFrame.window.origin.x < savedFrame.screen.origin.x {
                break x
            }

            newFrame.origin.x = visibleFrame.origin.x
        }
        y: if newFrame.origin.y < visibleFrame.origin.y {
            if let savedFrame, savedFrame.window.origin.y < savedFrame.screen.origin.y {
                break y
            }

            newFrame.origin.y = visibleFrame.origin.y
        }

        // Apply the new window frame
        window.setFrame(newFrame, display: true)
    }

    @objc private func ghosttyConfigDidChangeBase(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)
    }

    @objc private func ghosttyCommandPaletteDidToggle(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        toggleCommandPalette(nil)
    }

    @objc private func ghosttyMaximizeDidToggle(_ notification: Notification) {
        guard let window else { return }
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        window.zoom(nil)
    }

    static func shouldInterceptSurfaceClose(
        processExited: Bool,
        readerOpen: Bool
    ) -> Bool {
        !processExited && readerOpen
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let node = surfaceTree.root?.node(view: target) else { return }
        if let presentedSessionID,
           let session = workspaceStore.session(forTabID: presentedSessionID),
           Self.shouldInterceptSurfaceClose(
               processExited: target.processExited,
               readerOpen: session.readerStore.isOpen
           ) {
            session.readerStore.close()
            window?.makeFirstResponder(target)
            return
        }
        closeSurface(
            node,
            withConfirmation: (notification.userInfo?["process_alive"] as? Bool) ?? false)
    }

    @objc private func ghosttyDidNewSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let oldView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: oldView) != nil else { return }

        // Notification must contain our base config
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        // Determine our desired direction
        guard let directionAny = notification.userInfo?["direction"] else { return }
        guard let direction = directionAny as? ghostty_action_split_direction_e else { return }
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        newSplit(at: oldView, direction: splitDirection, baseConfig: config)
    }

    @objc private func ghosttyDidEqualizeSplits(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }

        // Check if target surface is in current controller's tree
        guard surfaceTree.contains(target) else { return }

        // Equalize the splits
        surfaceTree = surfaceTree.equalized()
    }

    @objc private func ghosttyDidFocusSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        // Get the direction from the notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.SplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitFocusDirection else { return }

        // Find the node for the target surface
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Find the next surface to focus
        guard let nextSurface = surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode) else {
            return
        }

        if surfaceTree.zoomed != nil {
            if derivedConfig.splitPreserveZoom.contains(.navigation) {
                surfaceTree = SplitTree(
                    root: surfaceTree.root,
                    zoomed: surfaceTree.root?.node(view: nextSurface))
            } else {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }
        }

        // Move focus to the next surface
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: nextSurface, from: target)
        }
    }

    @objc private func ghosttyDidToggleSplitZoom(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Toggle the zoomed state
        if surfaceTree.zoomed == targetNode {
            // Already zoomed, unzoom it
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            // We require that the split tree have splits
            guard surfaceTree.isSplit else { return }

            // Not zoomed or different node zoomed, zoom this node
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: targetNode)
        }

        // Move focus to our window. Importantly this ensures that if we click
        // the reset zoom button while this window is not focused, we become focused.
        window?.makeKeyAndOrderFront(nil)

        // Ensure focus stays on the target surface. We lose focus when we do
        // this so we need to grab it again.
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
        }
    }

    @objc private func ghosttyDidResizeSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Extract direction and amount from notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitResizeDirection else { return }

        guard let amountAny = notification.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] else { return }
        guard let amount = amountAny as? UInt16 else { return }

        // Convert Ghostty.SplitResizeDirection to SplitTree.Spatial.Direction
        let spatialDirection: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }

        // Use viewBounds for the spatial calculation bounds
        let bounds = CGRect(origin: .zero, size: surfaceTree.viewBounds())

        // Perform the resize using the new SplitTree resize method
        do {
            surfaceTree = try surfaceTree.resizing(node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Ghostty.logger.warning("failed to resize split: \(error, privacy: .public)")
        }
    }

    @objc private func ghosttyDidPresentTerminal(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        if !surfaceTree.contains(target) {
            // Target belongs to a non-presented tab (e.g. a command palette
            // "Focus" entry built from `allWorkspaceSurfaces`). Select its
            // owning session through the single mounting entry point first,
            // so it lands in `surfaceTree` before we try to focus it.
            guard let address = workspaceStore.address(forSurfaceID: target.id) else { return }
            selectSession(workspaceID: address.workspaceID, tabID: address.tabID)
            guard surfaceTree.contains(target) else { return }
        }

        // Bring the window to front and focus the surface.
        window?.makeKeyAndOrderFront(nil)

        // We use a small delay to ensure this runs after any UI cleanup
        // (e.g., command palette restoring focus to its original surface).
        Ghostty.moveFocus(to: target)
        Ghostty.moveFocus(to: target, delay: 0.1)

        // Show a brief highlight to help the user locate the presented terminal.
        target.highlight()
    }

    @objc private func ghosttySurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }

        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        _ = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: notification.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
    }

    // MARK: Local Events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .flagsChanged:
            localEventFlagsChanged(event)

        default:
            event
        }
    }

    private func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
        var surfaces: [Ghostty.SurfaceView] = surfaceTree.map { $0 }

        // If we're the main window receiving key input, then we want to avoid
        // calling this on our focused surface because that'll trigger a double
        // flagsChanged call.
        if NSApp.mainWindow == window {
            surfaces = surfaces.filter { $0 != focusedSurface }
        }

        for surface in surfaces {
            surface.flagsChanged(with: event)
        }

        return event
    }

    // MARK: TerminalViewDelegate

    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        focusedSurface = to

        // Important to cancel any prior subscriptions
        focusedSurfaceCancellables = []

        // Setup our title listener. If we have a focused surface we always use that.
        // Otherwise, we try to use our last focused surface. In either case, we only
        // want to care if the surface is in the tree so we don't listen to titles of
        // closed surfaces.
        if let titleSurface = focusedSurface ?? lastFocusedSurface,
           surfaceTree.contains(titleSurface) {
            // If we have a surface, we want to listen for title changes.
            titleSurface.$title
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            // There is no surface to listen to titles for.
            titleDidChange(to: "👻")
        }
    }

    // MARK: Per-session metadata

    /// Subscribes every live session to its own surface metadata.
    ///
    /// Each session watches the surface it considers focused (falling back to
    /// the first), so a background tab keeps reporting the title/pwd of the
    /// pane the user was actually looking at. Subscriptions are keyed by
    /// session id and only created for sessions that do not have one yet, so
    /// switching tabs does not churn the whole set.
    func rebuildSessionMetadataSubscriptions() {
        let sessions = workspaceStore.allSessions
        let liveIDs = Set(sessions.map(\.id))

        // Drop subscriptions for sessions that no longer exist.
        for id in sessionMetadataCancellables.keys where !liveIDs.contains(id) {
            sessionMetadataCancellables.removeValue(forKey: id)
        }

        for session in sessions {
            guard sessionMetadataCancellables[session.id] == nil else { continue }
            let tree = session.id == presentedSessionID ? surfaceTree : session.surfaceTree
            guard let surface = tree.first(where: { $0.id == session.focusedSurfaceID })
                ?? tree.first else { continue }

            var set: Set<AnyCancellable> = []
            surface.$title
                .combineLatest(surface.$bell)
                .sink { [weak self, weak session] title, bell in
                    guard let self, let session else { return }
                    session.title = self.computeTitle(title: title, bell: bell)
                    session.bell = bell
                }
                .store(in: &set)
            surface.$pwd
                .sink { [weak session] pwd in session?.pwd = pwd }
                .store(in: &set)
            sessionMetadataCancellables[session.id] = set
        }
    }

    private func computeTitle(title: String, bell: Bool) -> String {
        var result = title
        if bell && ghostty.config.bellFeatures.contains(.title) {
            result = "🔔 \(result)"
        }

        return result
    }

    private func titleDidChange(to: String) {
        lastComputedTitle = to
        applyTitleToWindow()

    }

    /// Derives the window title from the presented session's `titleOverride`
    /// (the same field the tab strip/sidebar read, set via
    /// `WorkspaceSessionStore.renameTab`), falling back to the legacy
    /// controller-level `titleOverride` (used only by window restoration) and
    /// then to the last computed terminal title. Internal, not private, so
    /// `Ghostty.App`'s `set_tab_title` handler can re-derive the window title
    /// immediately after writing through the store.
    func applyTitleToWindow() {
        guard let window else { return }

        let sessionOverride = presentedSessionID.flatMap { workspaceStore.session(forTabID: $0)?.titleOverride }
        if let effectiveOverride = sessionOverride ?? titleOverride, !effectiveOverride.isEmpty {
            window.title = computeTitle(
                title: effectiveOverride,
                bell: focusedSurface?.bell ?? false)
        } else {
            window.title = lastComputedTitle
        }

        // Mirror it for the in-window controls strip, which has to draw the
        // title itself. See ``windowTitle``.
        windowTitle = window.title
    }

    func pwdDidChange(to: URL?) {
        // Sync pwd to the selected session for sidebar display.
        workspaceStore.selectedSession?.pwd = to?.path

        guard let window else { return }

        if derivedConfig.macosTitlebarProxyIcon == .visible {
            // Use the 'to' URL directly
            window.representedURL = to
        } else {
            window.representedURL = nil
        }

        // Mirror it for the in-window controls strip. See
        // ``windowRepresentedURL``.
        windowRepresentedURL = window.representedURL
    }

    func cellSizeDidChange(to: NSSize) {
        guard derivedConfig.windowStepResize else { return }
        // Stage manager can sometimes present windows in such a way that the
        // cell size is temporarily zero due to the window being tiny. We can't
        // set content resize increments to this value, so avoid an assertion failure.
        guard to.width > 0 && to.height > 0 else { return }
        self.window?.contentResizeIncrements = to
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    private func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Ghostty.logger.warning("failed to replace node during split resize: \(error, privacy: .public)")
        }
    }

    private func splitDidDrop(
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }

        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Ghostty.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed to insert surface during drop: \(error, privacy: .public)")
                return
            }

            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Split")
            return
        }

        // Source is not in our tree - search other windows
        var sourceController: BaseTerminalController?
        var sourceNode: SplitTree<Ghostty.SurfaceView>.Node?
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            if let node = controller.surfaceTree.root?.node(view: source) {
                sourceController = controller
                sourceNode = node
                break
            }
        }

        guard let sourceController, let sourceNode else {
            Ghostty.logger.warning("source surface not found in any window during drop")
            return
        }

        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert surface during cross-window drop: \(error, privacy: .public)")
            return
        }

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)

        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surface else { return }
        let len = action.utf8CString.count
        if len == 0 { return }
        _ = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
        }
    }

    // MARK: Appearance

    /// Toggle the background opacity between transparent and opaque states.
    /// Do nothing if the configured background-opacity is >= 1 (already opaque).
    /// Subclasses should override this to add platform-specific checks and sync appearance.
    func toggleBackgroundOpacity() {
        // Do nothing if config is already fully opaque
        guard ghostty.config.backgroundOpacity < 1 else { return }

        // Do nothing if in fullscreen (transparency doesn't apply in fullscreen)
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        let newValue = !isBackgroundOpaque
        let controllers = NSApplication.shared.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        for controller in controllers {
            controller.isBackgroundOpaque = newValue
            controller.syncAppearance()
        }
    }

    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance. The list below should be updated
    /// as we add new things:
    ///
    ///  - ``toggleBackgroundOpacity``
    func syncAppearance() {
        // Purposely a no-op. This lets subclasses override this and we can call
        // it virtually from here.
    }

    // MARK: Fullscreen

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        var newStyle = mode.style(for: window)
        newStyle?.delegate = self
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = newStyle
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle!) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then set the new style for future use
                oldStyle.exit()
                self.fullscreenStyle = newStyle

                // We're done
                return
            }

            // Style is the same.
        } else {
            // We have no previous style
            self.fullscreenStyle = newStyle
        }
        guard let fullscreenStyle else { return }

        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }
    }

    func fullscreenDidChange() {
        guard let fullscreenStyle else { return }

        // When we enter fullscreen, we want to show the update overlay so that it
        // is easily visible. For native fullscreen this is visible by showing the
        // menubar but we don't want to rely on that.
        if fullscreenStyle.isFullscreen {
            updateOverlayIsVisible = true
        } else {
            updateOverlayIsVisible = defaultUpdateOverlayVisibility()
        }

        // A fullscreen transition changes whether the titlebar can host the
        // workspace controls: non-native fullscreen removes the titlebar
        // outright and native fullscreen moves it into an auto-hiding overlay.
        syncWorkspaceControlsPlacement()

        // Always resync our appearance
        syncAppearance()
    }

    // MARK: Workspace Controls

    /// Recomputes ``workspaceControlsPlacement`` and keeps the leading titlebar
    /// accessory in step with it.
    ///
    /// The two hosts are mutually exclusive on purpose: in native fullscreen the
    /// auto-hidden titlebar still slides down on hover, and its accessory would
    /// duplicate the buttons the in-window strip is already showing.
    func syncWorkspaceControlsPlacement() {
        let placement = computeWorkspaceControlsPlacement()
        workspaceControlsPlacement = placement
        (window as? TerminalWindow)?.workspaceControlsAccessoryHidden = !placement.showsTitlebarAccessory
    }

    /// The placement for this window. Base implementation keeps the controls in
    /// the sidebar header: it makes no assumption that the window has a titlebar
    /// (the quick terminal is a borderless panel) or room for a strip.
    /// `TerminalController` overrides this.
    func computeWorkspaceControlsPlacement() -> WorkspaceControlsPlacement {
        .sidebarHeader
    }

    /// Runs a reserved workspace command on behalf of this window's workspace
    /// controls, whichever host is currently rendering them.
    ///
    /// Routed through ``TerminalCommandRouter`` so a button click resolves its
    /// destination controller exactly the way `⌘N` / `⌘⇧T` and the menu items
    /// do, instead of assuming this controller.
    func performWorkspaceControlsCommand(_ command: TerminalCommandRouter.ReservedTerminalCommand) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let router = appDelegate.terminalCommands as TerminalCommandRouter?
        else { return }
        _ = router.perform(command, source: focusedSurface ?? surfaceTree.first)
    }

    // MARK: Clipboard Confirmation

    @objc private func onConfirmClipboardRequest(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let surface = target.surface else { return }

        // We need a window
        guard let window = self.window else { return }

        // Check whether we use non-native fullscreen
        guard let str = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String else { return }
        guard let state = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer? else { return }
        guard let request = notification.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey] as? Ghostty.ClipboardRequest else { return }

        // If we already have a clipboard confirmation view up, we ignore this request.
        // This shouldn't be possible...
        guard self.clipboardConfirmation == nil else {
            Ghostty.App.completeClipboardRequest(surface, data: "", state: state, confirmed: true)
            return
        }

        // Show our paste confirmation
        self.clipboardConfirmation = ClipboardConfirmationController(
            surface: surface,
            contents: str,
            request: request,
            state: state,
            delegate: self
        )
        window.beginSheet(self.clipboardConfirmation!.window!)
    }

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Ghostty.ClipboardRequest) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        self.clipboardConfirmation = nil

        // Close the sheet
        if let ccWindow = cc.window {
            window?.endSheet(ccWindow)
        }

        switch request {
        case let .osc_52_write(pasteboard):
            guard case .confirm = action else { break }
            let pb = pasteboard ?? NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString(cc.contents, forType: .string)
        case .osc_52_read, .paste:
            let str: String
            switch action {
            case .cancel:
                str = ""

            case .confirm:
                str = cc.contents
            }

            Ghostty.App.completeClipboardRequest(cc.surface, data: str, state: cc.state, confirmed: true)
        }
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()

        // Setup our undo manager.

        // Everything beyond here is setting up the window
        guard let window else { return }

        // We always initialize our fullscreen style to native if we can because
        // initialization sets up some state (i.e. observers). If its set already
        // somehow we don't do this.
        if fullscreenStyle == nil {
            fullscreenStyle = NativeFullscreen(window)
            fullscreenStyle?.delegate = self
        }

        // Set our update overlay state
        updateOverlayIsVisible = defaultUpdateOverlayVisibility()

        // Seed the strip's title mirror; `applyTitleToWindow` keeps it current
        // from here on, but a window created with a configured title never goes
        // through it.
        windowTitle = window.title
    }

    func defaultUpdateOverlayVisibility() -> Bool {
        guard let window else { return true }

        // No titlebar we always show the update overlay because it can't support
        // updates in the titlebar
        guard window.styleMask.contains(.titled) else {
            return true
        }

        // If it's a non terminal window we can't trust it has an update accessory,
        // so we always want to show the overlay.
        guard let window = window as? TerminalWindow else {
            return true
        }

        // Show the overlay if the window isn't.
        return !window.supportsUpdateAccessory
    }

    // MARK: NSWindowDelegate

    /// Check whether window should be closed without showing an alert
    func windowCanBeClosedWithoutConfirmation() -> Bool {
        // We must have a window. Is it even possible not to?
        guard let window = self.window else { return true }

        // Confirmation must consider EVERY virtual tab, not just the presented
        // one. All virtual tabs now live in this single controller, so a
        // background tab's running process is only reachable through the store;
        // checking `surfaceTree` alone would silently kill it on red-X or ⌘Q.
        let allSurfaces = allWorkspaceSurfaces

        // If we have no surfaces, close.
        if allSurfaces.isEmpty { return true }

        // If we already have an alert, continue with it
        guard alert == nil else { return false }

        // If our surfaces don't require confirmation, close.
        if !allSurfaces.contains(where: { $0.needsConfirmQuit }) { return true }

        return false
    }

    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !windowCanBeClosedWithoutConfirmation() else {
            return true
        }
        // We require confirmation, so show an alert as long as we aren't already.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            self?.window?.close()
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        // Unregister surfaces from the owner registry before any
        // other close work so the closing controller's surfaces immediately
        // become unavailable to live lookup.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.surfaceOwners?.unregister(ObjectIdentifier(self))
        }

        // Emit a final bell-state transition so any observers can clear state
        // without separately tracking NSWindow lifecycle events.
        if bell {
            bell = false
            NotificationCenter.default.post(
                name: .terminalWindowBellDidChangeNotification,
                object: self,
                userInfo: [Notification.Name.terminalWindowHasBellKey: false]
            )
        }

        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        window.contentView = nil

        // Make sure we clean up all our undos
        window.undoManager?.removeAllActions(withTarget: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // If when we become key our first responder is the window itself, then we
        // want to move focus to our focused terminal surface. This works around
        // various weirdness with moving surfaces around.
        if let window, window.firstResponder == window, let focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }

        // Becoming key can race with responder updates when activating a window.
        // Sync on the next runloop so split focus has settled first.
        DispatchQueue.main.async {
            self.syncFocusToSurfaceTree()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncSurfaceTreeOcclusionState()
    }

    private func syncSurfaceTreeOcclusionState() {
        let visible = self.window?.occlusionState.contains(.visible) ?? false
        for view in surfaceTree {
            if let surface = view.surface, view.isWindowVisible != visible {
                ghostty_surface_set_occlusion(surface, visible)
                view.isWindowVisible = visible
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    // MARK: First Responder

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        window.performClose(sender)
    }

    @IBAction func changeTabTitle(_ sender: Any) {
        // Native tabbing is disallowed, so there is no AppKit inline
        // tab-title editor to route through (removed with native tabbing,
        // row 33). This menu path is deliberately prompt-only; inline rename
        // is still reachable via the VirtualTabBar item's double-click and
        // its "Rename…" context menu entry, which write directly to the
        // session's `titleOverride` without going through this action.
        promptTabTitle()
    }

    @IBAction func splitRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @IBAction func splitLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_LEFT)
    }

    @IBAction func splitDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @IBAction func splitUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_UP)
    }

    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }

    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }

    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }

    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .up)
    }

    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .down)
    }

    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }

    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }

    @IBAction func equalizeSplits(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitEqualize(surface: surface)
    }

    @IBAction func moveSplitDividerUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .up, amount: 10)
    }

    @IBAction func moveSplitDividerDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .down, amount: 10)
    }

    @IBAction func moveSplitDividerLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .left, amount: 10)
    }

    @IBAction func moveSplitDividerRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .right, amount: 10)
    }

    private func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }

    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .reset)
    }

    @IBAction func toggleCommandPalette(_ sender: Any?) {
        commandPaletteIsShowing.toggle()
        if commandPaletteIsShowing {
            // Fix the incorrect focus when toggling from InlineTitleEditor
            // When toggling the command palette from the inline title editor,
            // the first responder state of the surface is changed quickly from true to false.

            // `makeFirstResponder:` is called by the title editor when finishing,
            // but it happens **after** the command palette is shown,
            // so the `focused` is set to `true` while the command palette is shown.
            // (Could be an AppKit issue as well, since the resign is not called after but the command palette is receiving `keyDown`).

            // Since `performKeyEquivalent(with:)` is called on all of the subviews
            // until one of the return `true` so the paste action is consumed by the surface
            // instead of the first responder (command palette).
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    @IBAction func find(_ sender: Any) {
        focusedSurface?.find(sender)
    }

    @IBAction func selectionForFind(_ sender: Any) {
        focusedSurface?.selectionForFind(sender)
    }

    @IBAction func scrollToSelection(_ sender: Any) {
        focusedSurface?.scrollToSelection(sender)
    }

    @IBAction func findNext(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }

    @IBAction func findPrevious(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }

    @IBAction func findHide(_ sender: Any) {
        focusedSurface?.findHide(sender)
    }

    @objc func resetTerminal(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.resetTerminal(surface: surface)
    }

    private struct DerivedConfig {
        let macosTitlebarProxyIcon: Ghostty.MacOSTitlebarProxyIcon
        let windowStepResize: Bool
        let focusFollowsMouse: Bool
        let splitPreserveZoom: Ghostty.Config.SplitPreserveZoom

        init() {
            self.macosTitlebarProxyIcon = .visible
            self.windowStepResize = false
            self.focusFollowsMouse = false
            self.splitPreserveZoom = .init()
        }

        init(_ config: Ghostty.Config) {
            self.macosTitlebarProxyIcon = config.macosTitlebarProxyIcon
            self.windowStepResize = config.windowStepResize
            self.focusFollowsMouse = config.focusFollowsMouse
            self.splitPreserveZoom = config.splitPreserveZoom
        }
    }
}

extension BaseTerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findHide):
            return focusedSurface?.searchState != nil

        default:
            return true
        }
    }

    // MARK: - Surface Color Scheme

    /// Update the surface tree's color scheme only when it actually changes.
    ///
    /// Calling ``ghostty_surface_set_color_scheme`` triggers
    /// ``syncAppearance(_:)`` via notification,
    /// so we avoid redundant calls.
    func updateColorSchemeForSurfaceTree() {
        /// Derive the target scheme from `window-theme` or system appearance.
        /// We set the scheme on surfaces so they pick the correct theme
        /// and let ``syncAppearance(_:)`` update the window accordingly.
        ///
        /// Using App's effectiveAppearance here to prevent incorrect updates.
        let themeAppearance = NSApplication.shared.effectiveAppearance
        let scheme: ghostty_color_scheme_e
        if themeAppearance.isDark {
            scheme = GHOSTTY_COLOR_SCHEME_DARK
        } else {
            scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        }
        guard scheme != appliedColorScheme else {
            return
        }
        for surfaceView in surfaceTree {
            if let surface = surfaceView.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }
        appliedColorScheme = scheme
    }
}

// MARK: Combine Methods

extension BaseTerminalController {
    /// Publishes an app-wide notification whenever this terminal window's aggregate
    /// bell state changes.
    private func setupBellNotificationPublisher() {
        bellStateCancellable = surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .map { $0.values.contains(true) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasBell in
                guard let self else { return }
                bell = hasBell
                // Sync bell to the selected session for sidebar display.
                workspaceStore.selectedSession?.bell = hasBell
                NotificationCenter.default.post(
                    name: .terminalWindowBellDidChangeNotification,
                    object: self,
                    userInfo: [Notification.Name.terminalWindowHasBellKey: hasBell]
                )
            }
    }

    /// Creates a publisher for values on all surfaces in this controller's tree.
    ///
    /// The publisher emits a dictionary of surface IDs to values whenever the tree changes
    /// or any surface publishes a new value for the key path.
    func surfaceValuesPublisher<Value>(
        valueKeyPath: KeyPath<Ghostty.SurfaceView, Value>,
        publisherKeyPath: KeyPath<Ghostty.SurfaceView, Published<Value>.Publisher>
    ) -> AnyPublisher<[Ghostty.SurfaceView.ID: Value], Never> {
        // `surfaceTree` can be replaced entirely when splits are added/removed/closed.
        // For each tree snapshot we build a fresh publisher that watches all surfaces
        // in that snapshot.
        $surfaceTree
            .map { tree in
                tree.valuesPublisher(
                    valueKeyPath: valueKeyPath,
                    publisherKeyPath: publisherKeyPath
                )
            }
            // Keep only the latest tree publisher active. This automatically cancels
            // subscriptions for old/removed surfaces when the tree changes.
            .switchToLatest()
            .eraseToAnyPublisher()
    }
}

// MARK: Notifications

extension Notification.Name {
    /// Terminal window aggregate bell state changed.
    static let terminalWindowBellDidChangeNotification = Notification.Name("com.mitchellh.ghostty.terminalWindowBellDidChange")
    static let terminalWindowHasBellKey = terminalWindowBellDidChangeNotification.rawValue + ".hasBell"
}
