import AppKit
import Combine
import Foundation
import GhosttyKit

// MARK: - Value-only structural projections

/// A value-only address identifying a single surface in the
/// workspace → tab → surface hierarchy. Carries no reference to any object.
struct SurfaceAddress: Hashable {
    let workspaceID: UUID
    let tabID: UUID
    let surfaceID: UUID
}

/// Value-only selection of one workspace and one tab within it.
struct Selection: Hashable {
    let workspaceID: UUID
    let tabID: UUID
}

/// Value-only projection of a session's surface tree topology.
///
/// Carries only UUIDs — never a `Ghostty.SurfaceView` reference. This is the
/// shape that flows through ``WorkspaceStructuralCandidate`` so candidates are
/// recursively value-only and stage/validate can be observed to emit nothing.
struct SurfaceTreeProjection: Hashable {
    /// Ordered list of surface UUIDs in tree iteration order.
    let surfaceIDs: [UUID]
    /// UUID of the focused surface within this tree, if any.
    let focusedSurfaceID: UUID?
    /// UUID of the remembered (last-focused) surface, if any.
    let rememberedSurfaceID: UUID?
}

/// Value-only projection of a single terminal session's structural state.
struct SessionStructuralProjection: Hashable, Identifiable {
    /// Stable tab/session UUID.
    let id: UUID
    /// Projected surface-tree topology.
    let surfaceTree: SurfaceTreeProjection
}

/// Value-only projection of a virtual tab, wrapping its session projection.
struct TabProjection: Hashable, Identifiable {
    /// Same as the wrapped session's id.
    let id: UUID
    /// The session structural projection.
    let session: SessionStructuralProjection
}

/// Value-only projection of a virtual workspace.
///
/// Carry-forward warning: the bare memberwise initializer resets every field
/// to its default, so any rebuild site that constructs a `WorkspaceProjection`
/// from an existing one MUST thread every field forward explicitly (or via
/// `with(...)`). The four rebuild sites are: `WorkspaceSessionStore.commit(_:)`
/// (session rebuild), the static `project(_ ws:)` projector,
/// `TerminalRestorableState+InteralState`'s v8 encode/decode, and
/// `TerminalController.makeRestoredV8` (plus the restore constructions it
/// feeds). Only `addWorkspace` may use the bare initializer, because it is the
/// one site that genuinely creates a brand-new workspace with no prior state.
/// `insertWorkspace` restores a workspace that ALREADY existed and therefore
/// takes the presentation fields as parameters — treating it as "brand-new"
/// is what silently reset directory/color/collapse on Close Workspace + Cmd+Z.
struct WorkspaceProjection: Hashable, Identifiable {
    let id: UUID
    let name: String
    let tabs: [TabProjection]
    let selectedTabID: UUID?
    /// User-assigned accent. Part of the projection so a recolor flows through
    /// the same validated transaction as any other structural edit.
    var color: TerminalTabColor = .none

    /// Whether the sidebar hides this workspace's tab rows.
    ///
    /// Purely presentational, but it lives in the projection so it survives
    /// commits and is persisted with the rest of the hierarchy.
    var isCollapsed: Bool = false

    /// Directory a new virtual tab should spawn in when nothing more specific
    /// (an explicit caller directory) applies. See
    /// `TerminalCommandRouter.resolvedConfig`. Kept in the projection so it
    /// carries through the same validated transaction as any other structural
    /// edit and survives persistence with the rest of the hierarchy.
    var defaultDirectory: String?

    /// Returns a copy with the supplied fields replaced.
    ///
    /// Every field is `let` by design, so edits rebuild rather than mutate.
    func with(
        name: String? = nil,
        tabs: [TabProjection]? = nil,
        selectedTabID: UUID?? = nil,
        color: TerminalTabColor? = nil,
        isCollapsed: Bool? = nil,
        defaultDirectory: String?? = nil
    ) -> WorkspaceProjection {
        WorkspaceProjection(
            id: id,
            name: name ?? self.name,
            tabs: tabs ?? self.tabs,
            selectedTabID: selectedTabID ?? self.selectedTabID,
            color: color ?? self.color,
            isCollapsed: isCollapsed ?? self.isCollapsed,
            defaultDirectory: defaultDirectory ?? self.defaultDirectory
        )
    }
}

/// Value-only proposed topology. Contains zero mutable reference types.
///
/// A candidate represents a complete proposed post-change structural state:
/// the full ordered workspace → tab → surface projection plus the desired
/// selection and the proposed ``mountGeneration`` to be assigned on commit.
/// Because every field is a value type, two candidates compare with `==` and
/// passing one around never leaks session or surface references.
struct WorkspaceStructuralCandidate: Hashable {
    /// Proposed ordered workspaces.
    let workspaces: [WorkspaceProjection]
    /// Proposed selection after commit.
    let selection: Selection
    /// Proposed mount generation. Commit installs this as the live generation.
    let proposedGeneration: UInt64
}

// MARK: - Workspace

/// A virtual workspace containing ordered terminal tabs.
/// Per DR-1, a workspace never creates or owns an NSWindow.
struct WorkspaceSession: Identifiable {
    let id: UUID
    var name: String
    var tabs: [TerminalSessionState]
    var selectedTabID: UUID?

    /// User-assigned accent tinting this workspace's sidebar section.
    var color: TerminalTabColor = .none

    /// Whether the sidebar hides this workspace's tab rows.
    var isCollapsed: Bool = false

    /// Directory a new virtual tab should spawn in when nothing more specific
    /// (an explicit caller directory) applies. See
    /// `TerminalCommandRouter.resolvedConfig`.
    var defaultDirectory: String?

    var selectedTab: TerminalSessionState? {
        guard let id = selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == id })
    }

    var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return tabs.isEmpty ? nil : 0 }
        return tabs.firstIndex(where: { $0.id == id })
    }
}

// MARK: - WorkspaceSessionStore

/// A per-controller store of virtual workspaces → tabs → sessions.
///
/// Per DR-1 / Phase 1, the store is owned by exactly one ordinary
/// `TerminalController` and exposes structural change through **one** published
/// property: ``snapshot``. Every structural mutation flows through the
/// ``stage`` → ``validate`` → ``commit`` transaction:
///
/// 1. `stage()` returns a value-only ``WorkspaceStructuralCandidate`` snapshot
///    of the current topology. Emitting nothing on `snapshot` or any session.
/// 2. The caller mutates the candidate (a value) and calls `validate(_:)`.
///    Validation reads only the candidate and live registry, emitting nothing.
/// 3. `commit(_:)` installs the candidate in a single `@Published` assignment
///    on `snapshot` and bumps ``mountGeneration``.
///
/// Session structural state (surface tree, focused/remembered surface IDs) is
/// **not** `@Published` on `TerminalSessionState`; only metadata publishers
/// remain. The store is therefore the sole structural authority.
///
/// This is distinct from the legacy `WorkspaceStore` singleton; this model
/// replaces it for ordinary controllers.
final class WorkspaceSessionStore: ObservableObject {
    /// Sole structural publisher. Replaces all previously published arrays/IDs.
    @Published private(set) var snapshot: Snapshot

    /// Monotonically increasing generation, bumped by every successful commit.
    /// Mounting compares this to the controller's last-presented generation.
    private(set) var mountGeneration: UInt64

    /// Live UUID → session reference table. Not published. Updated by
    /// ``register(_:)`` / ``unregister(_:)`` and pruned by `commit`.
    /// Lookups for live mounting go through this table after a commit.
    private var liveSessions: [UUID: TerminalSessionState] = [:]

    /// Surface UUID → tab UUID for fast source lookup. Derived from snapshot.
    private var surfaceToTab: [UUID: UUID] = [:]

    struct Snapshot {
        /// Ordered workspaces (carrying live session references for mounting).
        let workspaces: [WorkspaceSession]
        /// Current desired selection.
        let selection: Selection
        /// Generation at which this snapshot was installed.
        let mountGeneration: UInt64
    }

    /// Invoked inside `commit(_:)` after the new topology is resolved but
    /// **before** `snapshot` is assigned.
    ///
    /// The owning controller uses this to replace the `SurfaceOwnerRegistry`
    /// index so registry-backed resolution never observes a published topology
    /// that the registry has not caught up to. Set by the controller; the store
    /// itself has no knowledge of the registry.
    var willCommit: (([WorkspaceSession], Selection) -> Void)?

    // MARK: Init

    /// Empty store. Used only by tests; ordinary construction goes through
    /// ``init(initialSession:)`` or a full-snapshot builder.
    init() {
        self.mountGeneration = 0
        // A sentinel empty selection is required because Snapshot.selection is
        // non-optional. The empty snapshot's generation is zero and any
        // presented generation ≥ 0 means "nothing is presented".
        self.snapshot = Snapshot(
            workspaces: [],
            selection: Selection(workspaceID: UUID(), tabID: UUID()),
            mountGeneration: 0
        )
    }

    /// Creates a store with one workspace containing one tab with the given
    /// session. Used by the graph factory during ordinary initialization.
    convenience init(initialSession: TerminalSessionState) {
        self.init()
        liveSessions[initialSession.id] = initialSession
        let wsID = UUID()
        rebuildSurfaceIndex(for: [initialSession.id])
        let ws = WorkspaceSession(
            id: wsID,
            name: "Workspace 1",
            tabs: [initialSession],
            selectedTabID: initialSession.id
        )
        mountGeneration = 1
        snapshot = Snapshot(
            workspaces: [ws],
            selection: Selection(workspaceID: wsID, tabID: initialSession.id),
            mountGeneration: mountGeneration
        )
    }

    /// Creates a store from a fully-formed v8 restored hierarchy.
    ///
    /// `workspaces` must be non-empty and every workspace must have at least
    /// one tab; the caller (restoration) validates this before constructing.
    /// Emits no publisher events beyond the single initial snapshot install.
    convenience init(
        restoredWorkspaces workspaces: [WorkspaceSession],
        selection: Selection
    ) {
        self.init()
        precondition(!workspaces.isEmpty, "restored hierarchy must have at least one workspace")
        for ws in workspaces {
            precondition(!ws.tabs.isEmpty, "restored workspace must have at least one tab")
            for session in ws.tabs {
                liveSessions[session.id] = session
            }
        }
        rebuildSurfaceIndex(for: workspaces.flatMap { $0.tabs.map(\.id) })
        mountGeneration = 1
        snapshot = Snapshot(
            workspaces: workspaces,
            selection: selection,
            mountGeneration: mountGeneration
        )
    }

    // MARK: Live session registry

    /// Registers a live session so it can be referenced by subsequent commits.
    /// Registering emits **no** publisher events.
    func register(_ session: TerminalSessionState) {
        liveSessions[session.id] = session
    }

    /// Removes a session from the live registry and returns it. Removing emits
    /// **no** publisher events. The caller is responsible for `tearDown()` or
    /// transfer-lease handoff before unregistering.
    @discardableResult
    func unregister(_ sessionID: UUID) -> TerminalSessionState? {
        liveSessions.removeValue(forKey: sessionID)
    }

    /// Returns the live session for a tab UUID, if registered.
    func liveSession(forTabID tabID: UUID) -> TerminalSessionState? {
        liveSessions[tabID]
    }

    // MARK: Stage / Validate / Commit

    /// Returns a value-only candidate describing the current topology with a
    /// proposed next generation. Staging emits zero publisher events and
    /// mutates nothing.
    func stage() -> WorkspaceStructuralCandidate {
        WorkspaceStructuralCandidate(
            workspaces: snapshot.workspaces.map(Self.project),
            selection: snapshot.selection,
            proposedGeneration: snapshot.mountGeneration &+ 1
        )
    }

    /// Validates a candidate against the live registry without mutating or
    /// publishing anything. Returns `true` if every referenced tab/session has
    /// a registered live session, every workspace has at least one tab, the
    /// selection references existing IDs, all tab IDs are unique, and the
    /// proposed generation strictly exceeds the current generation.
    func validate(_ candidate: WorkspaceStructuralCandidate) -> Bool {
        // Generation must strictly advance.
        guard candidate.proposedGeneration > snapshot.mountGeneration else { return false }

        // Every referenced tab must have a registered live session.
        let referencedTabIDs = candidate.workspaces.flatMap { $0.tabs.map(\.id) }
        guard referencedTabIDs.allSatisfy({ liveSessions[$0] != nil }) else { return false }

        // Tab IDs unique across all workspaces.
        guard Set(referencedTabIDs).count == referencedTabIDs.count else { return false }

        // Workspace IDs unique.
        let wsIDs = candidate.workspaces.map(\.id)
        guard Set(wsIDs).count == wsIDs.count else { return false }

        // Each workspace has at least one tab.
        guard candidate.workspaces.allSatisfy({ !$0.tabs.isEmpty }) else { return false }

        // Selected tab IDs reference existing tabs within their workspace.
        for ws in candidate.workspaces {
            if let selId = ws.selectedTabID,
               !ws.tabs.contains(where: { $0.id == selId }) { return false }
        }

        // Selection references an existing workspace and tab.
        guard let selWS = candidate.workspaces.first(where: { $0.id == candidate.selection.workspaceID }),
              selWS.tabs.contains(where: { $0.id == candidate.selection.tabID }) else {
            return false
        }

        // The two representations of selection must agree. `Snapshot.selection`
        // is the global "what is presented" and `WorkspaceProjection
        // .selectedTabID` is the per-workspace "what to return to". If a
        // candidate could commit them out of sync, `selectedSession` (which
        // resolves through `selectedTabID`) would name a different tab than the
        // one actually presented — routing title/pwd updates to the wrong
        // session and restoring the wrong tab. Reject that state outright.
        guard selWS.selectedTabID == candidate.selection.tabID else { return false }

        return true
    }

    /// Applies a validated candidate atomically: rebuilds the workspaces from
    /// the candidate + live registry, rebuilds the surface index, bumps the
    /// generation, and replaces ``snapshot`` in a single `@Published`
    /// assignment. Invalid candidates are rejected without effect.
    func commit(_ candidate: WorkspaceStructuralCandidate) {
        guard validate(candidate) else { return }

        // Rebuild workspaces from candidate + live registry. The candidate
        // carries no references, so we resolve each tab from `liveSessions`.
        let newWorkspaces: [WorkspaceSession] = candidate.workspaces.map { proj in
            let tabs: [TerminalSessionState] = proj.tabs.compactMap { tp in
                liveSessions[tp.session.id]
            }
            // Sync structural projection back onto the live session so the
            // session's non-published structural fields match the candidate.
            for (tp, session) in zip(proj.tabs, tabs) {
                session.focusedSurfaceID = tp.session.surfaceTree.focusedSurfaceID
                session.rememberedSurfaceID = tp.session.surfaceTree.rememberedSurfaceID
            }
            return WorkspaceSession(
                id: proj.id,
                name: proj.name,
                tabs: tabs,
                selectedTabID: proj.selectedTabID,
                color: proj.color,
                isCollapsed: proj.isCollapsed,
                defaultDirectory: proj.defaultDirectory
            )
        }

        // Rebuild surface index.
        surfaceToTab.removeAll()
        for ws in newWorkspaces {
            for session in ws.tabs {
                for surface in session.surfaceTree {
                    surfaceToTab[surface.id] = session.id
                }
            }
        }

        // Replace the owner index BEFORE the snapshot is published.
        //
        // `snapshot` is `@Published`, so assigning it synchronously notifies
        // every SwiftUI subscriber. If the registry were updated after that
        // assignment, any registry-backed resolution running inside that
        // notification would see the previous topology. The plan's required
        // order is therefore stage → validate → registry → one publication →
        // mount, and this hook is the only place that can honor it for the
        // store's internal add/remove transactions.
        willCommit?(newWorkspaces, candidate.selection)

        mountGeneration = candidate.proposedGeneration
        snapshot = Snapshot(
            workspaces: newWorkspaces,
            selection: candidate.selection,
            mountGeneration: mountGeneration
        )
    }

    /// Builds a candidate whose `selection` AND the owning workspace's
    /// `selectedTabID` both name `tabID`.
    ///
    /// Selection is represented twice — globally in `Snapshot.selection` and
    /// per-workspace in `WorkspaceProjection.selectedTabID` — because
    /// re-entering a workspace must restore the tab that was last active *in
    /// that workspace*. Updating only the global copy leaves the per-workspace
    /// copy stale, which surfaces as: the wrong sidebar row highlighted, the
    /// presented tab's title/pwd written onto a different session (because
    /// `selectedSession` resolves through `selectedTabID`), the wrong tab
    /// restored on workspace re-entry, and the wrong tab persisted to v8.
    ///
    /// Every selection change goes through here so the two cannot drift.
    func candidateSelecting(
        workspaceID: UUID,
        tabID: UUID
    ) -> WorkspaceStructuralCandidate {
        let base = stage()
        let workspaces = base.workspaces.map { ws -> WorkspaceProjection in
            guard ws.id == workspaceID else { return ws }
            return ws.with(selectedTabID: .some(tabID))
        }
        return WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: Selection(workspaceID: workspaceID, tabID: tabID),
            proposedGeneration: base.proposedGeneration
        )
    }

    // MARK: - Reorder / rename / recolor
    //
    // Candidates are value-only and every field is `let`, so these rebuild
    // projections rather than mutate them. They all funnel through the same
    // stage → validate → commit path as any other structural change, so the
    // registry is replaced before publication and the generation advances once.

    /// Moves a tab to `index` within `workspaceID`, which may be a different
    /// workspace than the one that currently owns it.
    func moveTab(_ tabID: UUID, toWorkspace workspaceID: UUID, at index: Int) {
        let base = stage()
        var workspaces = base.workspaces

        guard let fromIdx = workspaces.firstIndex(where: { ws in
                  ws.tabs.contains { $0.id == tabID } }),
              let tabIdx = workspaces[fromIdx].tabs.firstIndex(where: { $0.id == tabID }),
              let toIdx = workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }

        // Moving the last tab out of a workspace would strand an empty
        // workspace, which the model forbids. Refuse rather than commit it.
        if fromIdx != toIdx && workspaces[fromIdx].tabs.count == 1 { return }

        var fromTabs = workspaces[fromIdx].tabs
        let moving = fromTabs.remove(at: tabIdx)

        if fromIdx == toIdx {
            let clamped = max(0, min(index, fromTabs.count))
            fromTabs.insert(moving, at: clamped)
            workspaces[fromIdx] = workspaces[fromIdx].with(
                tabs: fromTabs,
                selectedTabID: .some(workspaces[fromIdx].selectedTabID))
        } else {
            var toTabs = workspaces[toIdx].tabs
            let clamped = max(0, min(index, toTabs.count))
            toTabs.insert(moving, at: clamped)

            // Keep each workspace's remembered tab pointing at something live.
            let fromSelected = workspaces[fromIdx].selectedTabID == tabID
                ? fromTabs.first?.id
                : workspaces[fromIdx].selectedTabID
            workspaces[fromIdx] = workspaces[fromIdx].with(
                tabs: fromTabs, selectedTabID: .some(fromSelected))
            workspaces[toIdx] = workspaces[toIdx].with(
                tabs: toTabs, selectedTabID: .some(tabID))
        }

        // A dragged tab stays presented, now under its new owner.
        let selection = base.selection.tabID == tabID
            ? Selection(workspaceID: workspaces[toIdx].id, tabID: tabID)
            : base.selection

        commitReorder(WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: selection,
            proposedGeneration: base.proposedGeneration))
    }

    /// Moves a workspace to a new position in the sidebar order.
    func moveWorkspace(_ workspaceID: UUID, to index: Int) {
        let base = stage()
        var workspaces = base.workspaces
        guard let from = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let moving = workspaces.remove(at: from)
        let clamped = max(0, min(index, workspaces.count))
        workspaces.insert(moving, at: clamped)
        commitReorder(WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: base.selection,
            proposedGeneration: base.proposedGeneration))
    }

    /// Presents an `NSAlert` with an inline text field to rename a workspace,
    /// then commits the result via `renameWorkspace(_:to:)`. Shared by every
    /// call site that needs this flow (the command palette's "Rename
    /// Workspace" action and the sidebar's flattened-workspace header),
    /// which previously duplicated this `NSAlert` construction verbatim.
    /// No-ops if `workspaceID` no longer resolves, the alert is cancelled, or
    /// the entered name is empty/whitespace-only.
    @MainActor
    func promptRenameWorkspace(_ workspaceID: UUID) {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: workspace.name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        renameWorkspace(workspaceID, to: name)
    }

    /// Renames a workspace. An all-whitespace name is ignored.
    func renameWorkspace(_ workspaceID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyToWorkspace(workspaceID) { $0.with(name: trimmed) }
    }

    /// Sets a workspace's accent color.
    func setWorkspaceColor(_ workspaceID: UUID, to color: TerminalTabColor) {
        applyToWorkspace(workspaceID) { $0.with(color: color) }
    }

    /// Sets or clears a workspace's default working directory. Passing `nil`
    /// clears it (falls through to the next precedence rung in
    /// `TerminalCommandRouter.resolvedConfig`).
    func setWorkspaceDefaultDirectory(_ workspaceID: UUID, to directory: String?) {
        applyToWorkspace(workspaceID) { $0.with(defaultDirectory: .some(directory)) }
    }

    private func applyToWorkspace(
        _ workspaceID: UUID,
        _ transform: (WorkspaceProjection) -> WorkspaceProjection
    ) {
        let base = stage()
        var workspaces = base.workspaces
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[idx] = transform(workspaces[idx])
        commitReorder(WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: base.selection,
            proposedGeneration: base.proposedGeneration))
    }

    /// Collapses or expands a workspace's tab list in the sidebar.
    func setWorkspaceCollapsed(_ workspaceID: UUID, _ collapsed: Bool) {
        applyToWorkspace(workspaceID) { $0.with(isCollapsed: collapsed) }
    }

    /// Toggles a workspace's collapsed state.
    func toggleWorkspaceCollapsed(_ workspaceID: UUID) {
        guard let ws = snapshot.workspaces.first(where: { $0.id == workspaceID }) else { return }
        setWorkspaceCollapsed(workspaceID, !ws.isCollapsed)
    }

    /// Collapses every workspace except the presented one.
    ///
    /// The presented workspace stays open because collapsing it would hide the
    /// tab the user is currently looking at.
    func collapseAllExceptSelected() {
        let keep = snapshot.selection.workspaceID
        let base = stage()
        let workspaces = base.workspaces.map { $0.with(isCollapsed: $0.id != keep) }
        commitReorder(WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: base.selection,
            proposedGeneration: base.proposedGeneration))
    }

    /// Expands every workspace.
    func expandAll() {
        let base = stage()
        let workspaces = base.workspaces.map { $0.with(isCollapsed: false) }
        commitReorder(WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: base.selection,
            proposedGeneration: base.proposedGeneration))
    }

    /// Renames a tab via its title override. An empty name clears the override
    /// so the terminal's own title takes over again.
    ///
    /// Metadata only, so no structural commit: the session's own publisher is
    /// what drives the sidebar and the tab strip.
    func renameTab(_ tabID: UUID, to name: String) {
        guard let session = session(forTabID: tabID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleOverride = trimmed.isEmpty ? nil : trimmed
    }

    /// Sets a tab's background tint. Metadata only, as above.
    func setTabColor(_ tabID: UUID, to color: TerminalTabColor) {
        guard let session = session(forTabID: tabID) else { return }
        session.tabColor = color == .none ? nil : String(color.rawValue)
    }

    /// Commits a reordered/renamed candidate, repairing the selection pair
    /// first so an edit cannot trip the selection-agreement invariant.
    private func commitReorder(_ candidate: WorkspaceStructuralCandidate) {
        var workspaces = candidate.workspaces
        guard let idx = workspaces.firstIndex(where: {
            $0.id == candidate.selection.workspaceID
        }) else { return }

        var selection = candidate.selection
        if !workspaces[idx].tabs.contains(where: { $0.id == selection.tabID }) {
            guard let fallback = workspaces[idx].tabs.first?.id else { return }
            selection = Selection(workspaceID: workspaces[idx].id, tabID: fallback)
        }
        workspaces[idx] = workspaces[idx].with(selectedTabID: .some(selection.tabID))

        let fixed = WorkspaceStructuralCandidate(
            workspaces: workspaces,
            selection: selection,
            proposedGeneration: candidate.proposedGeneration)
        guard validate(fixed) else { return }
        commit(fixed)
    }

    // MARK: Selection

    var selectedWorkspace: WorkspaceSession? {
        snapshot.workspaces.first(where: { $0.id == snapshot.selection.workspaceID })
    }

    var selectedSession: TerminalSessionState? {
        selectedWorkspace?.selectedTab
    }

    var selectedWorkspaceIndex: Int? {
        snapshot.workspaces.firstIndex(where: { $0.id == snapshot.selection.workspaceID })
    }

    // MARK: Enumeration

    /// Deterministic workspace-then-tab enumeration of all sessions.
    var allSessions: [TerminalSessionState] {
        snapshot.workspaces.flatMap(\.tabs)
    }

    /// Deterministic workspace-then-tab enumeration of all surface UUIDs.
    var allSurfaceIDs: [UUID] {
        allSessions.flatMap { session in
            session.surfaceTree.map(\.id)
        }
    }

    // MARK: Lookup

    /// Returns the tab UUID that owns the given surface, if live.
    func tabID(forSurfaceID surfaceID: UUID) -> UUID? {
        surfaceToTab[surfaceID]
    }

    /// Returns the session that owns the given surface, if live.
    func session(forSurfaceID surfaceID: UUID) -> TerminalSessionState? {
        guard let tabID = surfaceToTab[surfaceID] else { return nil }
        return session(forTabID: tabID)
    }

    /// Returns the session with the given tab UUID, if live.
    func session(forTabID tabID: UUID) -> TerminalSessionState? {
        for ws in snapshot.workspaces {
            if let tab = ws.tabs.first(where: { $0.id == tabID }) {
                return tab
            }
        }
        return nil
    }

    /// Returns the workspace that contains the given tab, if live.
    func workspace(forTabID tabID: UUID) -> WorkspaceSession? {
        snapshot.workspaces.first(where: { ws in ws.tabs.contains(where: { $0.id == tabID }) })
    }

    /// Returns the workspace that contains the given surface, if live.
    func workspace(forSurfaceID surfaceID: UUID) -> WorkspaceSession? {
        guard let tabID = surfaceToTab[surfaceID] else { return nil }
        return workspace(forTabID: tabID)
    }

    /// Returns the full ``SurfaceAddress`` for a surface, if live.
    func address(forSurfaceID surfaceID: UUID) -> SurfaceAddress? {
        guard let tabID = surfaceToTab[surfaceID],
              let ws = workspace(forTabID: tabID) else { return nil }
        return SurfaceAddress(workspaceID: ws.id, tabID: tabID, surfaceID: surfaceID)
    }

    // MARK: Workspace operations

    /// Adds a new workspace with one initial session. Registers the session,
    /// stages, commits, and returns the new workspace UUID.
    @discardableResult
    func addWorkspace(name: String? = nil, initialSession: TerminalSessionState) -> UUID {
        register(initialSession)
        var candidate = stage()
        let wsID = UUID()
        // Numbering by count produces duplicates as soon as a workspace in the
        // middle is closed (close #2 of 1-2-3 and the next add is "Workspace 3"
        // again). Pick the lowest unused number instead.
        let newWS = WorkspaceProjection(
            id: wsID,
            name: name ?? Self.nextWorkspaceName(existing: candidate.workspaces),
            tabs: [TabProjection(
                id: initialSession.id,
                session: Self.project(initialSession)
            )],
            selectedTabID: initialSession.id
        )
        candidate = WorkspaceStructuralCandidate(
            workspaces: candidate.workspaces + [newWS],
            selection: Selection(workspaceID: wsID, tabID: initialSession.id),
            proposedGeneration: candidate.proposedGeneration
        )
        guard validate(candidate) else { return wsID }
        commit(candidate)
        return wsID
    }

    /// Selects a workspace by ID. No-op if the workspace does not exist.
    func selectWorkspace(_ id: UUID) {
        guard let ws = snapshot.workspaces.first(where: { $0.id == id }) else { return }
        let tabID = ws.selectedTabID ?? ws.tabs.first?.id
        guard let tabID else { return }
        let candidate = candidateSelecting(workspaceID: id, tabID: tabID)
        if validate(candidate) { commit(candidate) }
    }

    /// Selects a workspace by index.
    func selectWorkspace(at index: Int) {
        guard snapshot.workspaces.indices.contains(index) else { return }
        selectWorkspace(snapshot.workspaces[index].id)
    }

    /// Removes a workspace. If it's the selected one, selects the nearest
    /// remaining. Returns the removed workspace's sessions for undo/teardown.
    @discardableResult
    func removeWorkspace(_ id: UUID) -> [TerminalSessionState] {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == id }) else { return [] }

        // Refuse to remove the final workspace. A controller must always own at
        // least one workspace with at least one tab, and the returned array is
        // an ownership transfer: callers wrap it in a destructive undo lease and
        // will tear the sessions down. Returning live sessions here without
        // committing the removal would kill PTYs still held by the store.
        guard snapshot.workspaces.count > 1 else { return [] }

        let removed = snapshot.workspaces[index]

        var candidate = stage()
        var newWS = candidate.workspaces
        newWS.remove(at: index)

        // Choose a new selection if we removed the selected workspace.
        let newSelection: Selection
        if candidate.selection.workspaceID == id {
            guard let nearest = newWS.first,
                  let tabID = nearest.selectedTabID ?? nearest.tabs.first?.id else {
                // Unreachable given the count guard above, but never report a
                // removal that was not committed.
                return []
            }
            newSelection = Selection(workspaceID: nearest.id, tabID: tabID)
        } else {
            newSelection = candidate.selection
        }

        candidate = WorkspaceStructuralCandidate(
            workspaces: newWS,
            selection: newSelection,
            proposedGeneration: candidate.proposedGeneration
        )
        guard validate(candidate) else { return [] }
        commit(candidate)
        return removed.tabs
    }

    // MARK: Tab operations

    /// Adds a new tab to the selected (or specified) workspace. Registers the
    /// session, stages, commits, and returns the new tab UUID.
    @discardableResult
    func addTab(_ session: TerminalSessionState, toWorkspace workspaceID: UUID? = nil) -> UUID {
        register(session)
        var candidate = stage()
        let targetID = workspaceID ?? candidate.selection.workspaceID
        guard let targetIndex = candidate.workspaces.firstIndex(where: { $0.id == targetID }) else {
            // No workspace exists; create one.
            return addWorkspace(initialSession: session)
        }

        var newWS = candidate.workspaces
        let oldWS = newWS[targetIndex]
        let newTabProj = TabProjection(
            id: session.id,
            session: Self.project(session)
        )
        // Expand on add: a new tab dropped into a collapsed workspace would
        // otherwise be selected but invisible.
        let updatedWS = oldWS.with(
            tabs: oldWS.tabs + [newTabProj],
            selectedTabID: .some(session.id),
            isCollapsed: false)
        newWS[targetIndex] = updatedWS

        candidate = WorkspaceStructuralCandidate(
            workspaces: newWS,
            selection: Selection(workspaceID: targetID, tabID: session.id),
            proposedGeneration: candidate.proposedGeneration
        )
        guard validate(candidate) else { return session.id }
        commit(candidate)
        return session.id
    }

    /// Re-inserts a previously removed session at a specific index, used by
    /// undo so a restored tab lands back in its original position.
    ///
    /// The caller must `register(_:)` the session first. If the workspace no
    /// longer exists (it was itself closed), this falls back to creating a new
    /// workspace so the restored session is never silently dropped.
    @discardableResult
    func insertTab(
        _ session: TerminalSessionState,
        intoWorkspace workspaceID: UUID,
        at index: Int?
    ) -> UUID {
        register(session)
        var candidate = stage()
        guard let targetIndex = candidate.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return addWorkspace(initialSession: session)
        }

        var newWS = candidate.workspaces
        let oldWS = newWS[targetIndex]
        let newTabProj = TabProjection(
            id: session.id,
            session: Self.project(session)
        )
        var tabs = oldWS.tabs
        let clamped = min(max(index ?? tabs.count, 0), tabs.count)
        tabs.insert(newTabProj, at: clamped)

        newWS[targetIndex] = oldWS.with(tabs: tabs, selectedTabID: .some(session.id))

        candidate = WorkspaceStructuralCandidate(
            workspaces: newWS,
            selection: Selection(workspaceID: workspaceID, tabID: session.id),
            proposedGeneration: candidate.proposedGeneration
        )
        guard validate(candidate) else { return session.id }
        commit(candidate)
        return session.id
    }

    /// Re-inserts a previously removed workspace with all of its sessions at a
    /// specific index. Used by undo so a restored workspace lands back in its
    /// original position with its original identity and tab order.
    ///
    /// The caller must `register(_:)` every session first.
    /// Re-inserts a workspace, preserving its presentation state.
    ///
    /// The only caller is `closeWorkspace`'s undo handler, which restores a
    /// workspace that ALREADY EXISTED. Building the projection with the bare
    /// memberwise initializer here silently reset `defaultDirectory`, `color`
    /// and `isCollapsed` to their defaults, so Close Workspace followed by
    /// Cmd+Z quietly discarded the user's directory, color and collapse
    /// choices. Those fields are therefore parameters rather than defaults.
    @discardableResult
    func insertWorkspace(
        id workspaceID: UUID,
        name: String,
        sessions: [TerminalSessionState],
        selectedTabID: UUID?,
        at index: Int?,
        defaultDirectory: String?,
        color: TerminalTabColor,
        isCollapsed: Bool
    ) -> UUID {
        guard !sessions.isEmpty else { return workspaceID }
        for session in sessions {
            register(session)
        }

        var candidate = stage()
        let tabs = sessions.map { session in
            TabProjection(id: session.id, session: Self.project(session))
        }
        let selected = selectedTabID.flatMap { id in
            sessions.contains(where: { $0.id == id }) ? id : nil
        } ?? sessions[0].id

        var newWS = candidate.workspaces
        let clamped = min(max(index ?? newWS.count, 0), newWS.count)
        newWS.insert(
            WorkspaceProjection(
                id: workspaceID,
                name: name,
                tabs: tabs,
                selectedTabID: selected,
                color: color,
                isCollapsed: isCollapsed,
                defaultDirectory: defaultDirectory
            ),
            at: clamped
        )

        candidate = WorkspaceStructuralCandidate(
            workspaces: newWS,
            selection: Selection(workspaceID: workspaceID, tabID: selected),
            proposedGeneration: candidate.proposedGeneration
        )
        guard validate(candidate) else { return workspaceID }
        commit(candidate)
        return workspaceID
    }

    /// Selects a tab within its workspace.
    func selectTab(_ tabID: UUID) {
        guard let ws = snapshot.workspaces.first(where: {
            $0.tabs.contains(where: { $0.id == tabID })
        }) else { return }
        let candidate = candidateSelecting(workspaceID: ws.id, tabID: tabID)
        if validate(candidate) { commit(candidate) }
    }

    /// Removes a tab from its workspace. If the workspace becomes empty, it is
    /// removed too. Returns the removed session for undo/teardown, or nil if
    /// not found. The session remains in the live registry; the caller must
    /// `unregister` and `tearDown` it after any undo bookkeeping.
    @discardableResult
    func removeTab(_ tabID: UUID) -> TerminalSessionState? {
        guard let wi = snapshot.workspaces.firstIndex(where: {
            $0.tabs.contains(where: { $0.id == tabID })
        }) else { return nil }
        let session = snapshot.workspaces[wi].tabs.first(where: { $0.id == tabID })
        guard let session else { return nil }

        var candidate = stage()
        var newWS = candidate.workspaces
        var removedWsID: UUID?
        let oldWS = newWS[wi]
        let newTabs = oldWS.tabs.filter { $0.id != tabID }
        if newTabs.isEmpty {
            newWS.remove(at: wi)
            removedWsID = oldWS.id
        } else {
            let newSelected: UUID?
            if oldWS.selectedTabID == tabID {
                let oldTabIndex = oldWS.tabs.firstIndex(where: { $0.id == tabID }) ?? 0
                newSelected = newTabs[min(oldTabIndex, newTabs.count - 1)].id
            } else {
                newSelected = oldWS.selectedTabID
            }
            newWS[wi] = oldWS.with(tabs: newTabs, selectedTabID: .some(newSelected))
        }

        // Choose a new selection if we removed the selected tab.
        //
        // Stay in the workspace the tab was closed from. `removedWsID` is only
        // set when that workspace itself became empty and was removed; when it
        // survives, jumping to `workspaces.first` would teleport the user out
        // of the workspace they were working in.
        let newSelection: Selection
        if candidate.selection.tabID == tabID {
            let owning = removedWsID == nil
                ? newWS.first(where: { $0.id == candidate.selection.workspaceID })
                : nil
            guard let nearest = owning ?? newWS.first,
                  let nearestTab = nearest.selectedTabID ?? nearest.tabs.first?.id else {
                return nil
            }
            newSelection = Selection(workspaceID: nearest.id, tabID: nearestTab)
        } else {
            newSelection = candidate.selection
        }

        candidate = WorkspaceStructuralCandidate(
            workspaces: newWS,
            selection: newSelection,
            proposedGeneration: candidate.proposedGeneration
        )
        guard validate(candidate) else { return nil }
        commit(candidate)
        return session
    }

    // MARK: Validation (for debug assertions)

    var isValid: Bool {
        // Each workspace must have at least one tab.
        guard snapshot.workspaces.allSatisfy({ !$0.tabs.isEmpty }) else { return false }
        // Selected workspace must exist.
        if !snapshot.workspaces.contains(where: { $0.id == snapshot.selection.workspaceID }) { return false }
        // Tab IDs must be unique across all workspaces.
        let allTabIDs = allSessions.map(\.id)
        guard Set(allTabIDs).count == allTabIDs.count else { return false }
        // Selected tab IDs must reference existing tabs.
        for ws in snapshot.workspaces {
            if let selId = ws.selectedTabID, !ws.tabs.contains(where: { $0.id == selId }) { return false }
        }
        return true
    }

    // MARK: Private helpers

    /// Rebuilds the surface UUID → tab UUID index from a list of live sessions.
    private func rebuildSurfaceIndex(for tabIDs: [UUID]) {
        surfaceToTab.removeAll()
        for tabID in tabIDs {
            guard let session = liveSessions[tabID] else { continue }
            for surface in session.surfaceTree {
                surfaceToTab[surface.id] = tabID
            }
        }
    }

    /// Projects a live session into a value-only structural projection.
    private static func project(_ session: TerminalSessionState) -> SessionStructuralProjection {
        SessionStructuralProjection(
            id: session.id,
            surfaceTree: SurfaceTreeProjection(
                surfaceIDs: session.surfaceTree.map(\.id),
                focusedSurfaceID: session.focusedSurfaceID,
                rememberedSurfaceID: session.rememberedSurfaceID
            )
        )
    }

    /// Lowest unused "Workspace N" name.
    private static func nextWorkspaceName(existing: [WorkspaceProjection]) -> String {
        let used = Set(existing.compactMap { ws -> Int? in
            guard ws.name.hasPrefix("Workspace ") else { return nil }
            return Int(ws.name.dropFirst("Workspace ".count))
        })
        var n = 1
        while used.contains(n) { n += 1 }
        return "Workspace \(n)"
    }

    /// Projects a live workspace into a value-only structural projection.
    private static func project(_ ws: WorkspaceSession) -> WorkspaceProjection {
        WorkspaceProjection(
            id: ws.id,
            name: ws.name,
            tabs: ws.tabs.map { TabProjection(id: $0.id, session: project($0)) },
            selectedTabID: ws.selectedTabID,
            color: ws.color,
            isCollapsed: ws.isCollapsed,
            defaultDirectory: ws.defaultDirectory
        )
    }
}
