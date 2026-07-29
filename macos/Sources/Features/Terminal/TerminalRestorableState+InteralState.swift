import AppKit

extension TerminalRestorableState {
    /// A single virtual tab's persisted state (v8).
    struct TabState<ViewType: NSView & Codable & Identifiable>: Codable {
        let id: UUID
        let surfaceTree: SplitTree<ViewType>
        let focusedSurfaceID: String?
        let title: String
        let pwd: String?
        let tabColor: String?
        let titleOverride: String?
        let isRestorable: Bool
    }

    /// A single virtual workspace's persisted state (v8).
    struct WorkspaceState<ViewType: NSView & Codable & Identifiable>: Codable {
        let id: UUID
        let name: String
        let tabs: [TabState<ViewType>]
        let selectedTabID: UUID?
        /// User-assigned accent. Optional so archives written before colors
        /// existed still decode.
        var color: TerminalTabColor?
        /// Sidebar collapse state. Optional for the same reason.
        var isCollapsed: Bool?
        /// Default working directory for new tabs in this workspace. Optional
        /// for the same reason — archives written before this field existed
        /// still decode (absent key → `nil` via the synthesized
        /// `decodeIfPresent` for `Optional`-typed stored properties).
        var defaultDirectory: String?
    }

    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8 (Chostty virtual workspace hierarchy)
        //
        // The full Workspace → Virtual Tab → Pane hierarchy. `surfaceTree` above
        // remains the currently-presented tree for compatibility with the
        // existing restore path; `workspaces` carries every workspace so a
        // restart restores the entire hierarchy, not just the selected tab.
        //
        // Optional so the type still decodes when a producer omits them, and so
        // existing unit-test fixtures constructing InternalState directly keep
        // compiling.
        let physicalID: UUID?
        let workspaces: [WorkspaceState<ViewType>]?
        let selectedWorkspaceID: UUID?
        let selectedTabID: UUID?

        init(
            focusedSurface: String?,
            surfaceTree: SplitTree<ViewType>,
            effectiveFullscreenMode: FullscreenMode?,
            tabColor: TerminalTabColor?,
            titleOverride: String?,
            physicalID: UUID? = nil,
            workspaces: [WorkspaceState<ViewType>]? = nil,
            selectedWorkspaceID: UUID? = nil,
            selectedTabID: UUID? = nil
        ) {
            self.focusedSurface = focusedSurface
            self.surfaceTree = surfaceTree
            self.effectiveFullscreenMode = effectiveFullscreenMode
            self.tabColor = tabColor
            self.titleOverride = titleOverride
            self.physicalID = physicalID
            self.workspaces = workspaces
            self.selectedWorkspaceID = selectedWorkspaceID
            self.selectedTabID = selectedTabID
        }
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        // Snapshot the full virtual hierarchy. The presented tree is written
        // back into its owning session first so the encoded hierarchy matches
        // exactly what is on screen.
        let snapshot = controller.workspaceStore.snapshot
        let presentedID = controller.presentedSessionID

        let workspaces: [TerminalRestorableState.WorkspaceState<Ghostty.SurfaceView>] =
            snapshot.workspaces.map { ws in
                let tabs = ws.tabs.map { session -> TerminalRestorableState.TabState<Ghostty.SurfaceView> in
                    // The presented session's live tree is on the controller, not
                    // yet written back into the session, so prefer it.
                    let tree = (session.id == presentedID)
                        ? controller.surfaceTree
                        : session.surfaceTree
                    let focused = (session.id == presentedID)
                        ? controller.focusedSurface?.id
                        : session.focusedSurfaceID
                    return .init(
                        id: session.id,
                        surfaceTree: tree,
                        focusedSurfaceID: focused?.uuidString,
                        title: session.title,
                        pwd: session.pwd,
                        tabColor: session.tabColor,
                        titleOverride: session.titleOverride,
                        isRestorable: session.isRestorable
                    )
                }
                return .init(
                    id: ws.id,
                    name: ws.name,
                    tabs: tabs,
                    selectedTabID: ws.selectedTabID,
                    color: ws.color,
                    isCollapsed: ws.isCollapsed,
                    defaultDirectory: ws.defaultDirectory
                )
            }

        // CRITICAL: do not also encode the presented tree in the flat
        // `surfaceTree` field. `Ghostty.SurfaceView.init(from:)` is not a
        // passive value decode — it constructs a live libghostty surface and
        // spawns a PTY, reusing the persisted UUID. Encoding the presented tree
        // both flat and inside `workspaces` would therefore materialize every
        // presented surface twice on restore: duplicate processes plus two live
        // views sharing one UUID (which is the key used by the owner registry
        // and the store's surface index).
        //
        // `workspaces` is the single source of truth for v8. The flat field is
        // kept empty purely because the property is non-optional in the shape
        // that `CodableBridge` already persists.
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: SplitTree<Ghostty.SurfaceView>(),
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            physicalID: controller.physicalUUID,
            workspaces: workspaces,
            selectedWorkspaceID: snapshot.selection.workspaceID,
            selectedTabID: snapshot.selection.tabID
        )
    }
}
