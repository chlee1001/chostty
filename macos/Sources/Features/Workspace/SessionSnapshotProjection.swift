import AppKit
import Foundation

/// Converts between the live workspace graph and the ``AppSessionSnapshot``
/// value layer.
///
/// The two directions are asymmetric. Reading is pure but touches `NSView`
/// properties, so it is main-thread only. Writing creates surfaces, and a
/// surface costs a PTY, a renderer thread and three IO threads, so leaf
/// creation is injected: production builds a real surface, tests build
/// `spawnsSurface: false` views and start nothing.
enum SessionSnapshotProjection {
    /// Builds the live view for one leaf.
    ///
    /// `nil` means the pane could not be created. A view whose `error` is set
    /// also failed to initialize. Either failure rejects the whole tree.
    typealias SurfaceFactory = (PaneLeafSnapshot) -> Ghostty.SurfaceView?

    // MARK: - Live to value

    /// `nil` for an empty tree, which is how a tab with no panes is stored.
    static func paneTree(from tree: SplitTree<Ghostty.SurfaceView>) -> PaneTreeSnapshot? {
        guard let root = tree.root else { return nil }
        return paneTree(fromNode: root)
    }

    private static func paneTree(fromNode node: SplitTree<Ghostty.SurfaceView>.Node) -> PaneTreeSnapshot {
        switch node {
        case .leaf(let view):
            return .leaf(leaf(from: view))

        case .split(let split):
            return .split(
                direction: direction(from: split.direction),
                ratio: split.ratio,
                left: paneTree(fromNode: split.left),
                right: paneTree(fromNode: split.right)
            )
        }
    }

    /// An empty title is stored as `nil` so a hydrated pane never shows blank.
    /// Shell-controlled metadata is bounded before reaching file validation.
    static func leaf(from view: Ghostty.SurfaceView) -> PaneLeafSnapshot {
        let title = truncatedToStringLimit(view.title)
        return PaneLeafSnapshot(
            uuid: view.id,
            cwd: view.pwd.map(truncatedToStringLimit),
            title: title.isEmpty ? nil : title
        )
    }

    private static func truncatedToStringLimit(_ value: String) -> String {
        guard value.utf8.count > SessionSnapshotValidator.Limits.stringLength else {
            return value
        }
        var remaining = SessionSnapshotValidator.Limits.stringLength
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let byteCount = value[end..<next].utf8.count
            guard byteCount <= remaining else { break }
            remaining -= byteCount
            end = next
        }
        return String(value[..<end])
    }

    /// `SplitTree.zoomed` is a node, and every zoom the app performs targets a
    /// leaf (`toggleZoom` resolves it with `node(view:)`). An interior node has
    /// no representation here and is recorded as not zoomed rather than
    /// guessed at.
    static func zoomedPaneID(in tree: SplitTree<Ghostty.SurfaceView>) -> UUID? {
        guard let zoomed = tree.zoomed else { return nil }
        if case .leaf(let view) = zoomed { return view.id }
        return nil
    }

    /// Projects a live session (virtual tab) into its value form.
    static func tab(from session: TerminalSessionState) -> TabSnapshot {
        TabSnapshot(
            id: session.id,
            titleOverride: session.titleOverride.map(truncatedToStringLimit),
            tabColor: session.tabColor.map(truncatedToStringLimit),
            paneTree: paneTree(from: session.surfaceTree),
            focusedPaneID: session.focusedSurfaceID,
            zoomedPaneID: zoomedPaneID(in: session.surfaceTree)
        )
    }

    /// `pendingTabs` covers tabs that have not been hydrated yet. A pending
    /// entry preserves its stored tree and focus only while its live
    /// `surfaceTree` is empty; a live tree always wins over a stale entry.
    ///
    /// Invariant: a pending tab's stored ``TabSnapshot`` is byte-equivalent in
    /// the next written snapshot, except for the sidebar-edited
    /// `titleOverride` and `tabColor`.
    static func workspace(
        from workspace: WorkspaceSession,
        pendingTabs: [UUID: TabSnapshot] = [:]
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: workspace.id,
            name: truncatedToStringLimit(workspace.name),
            color: workspace.color,
            isCollapsed: workspace.isCollapsed,
            defaultDirectory: workspace.defaultDirectory.map(truncatedToStringLimit),
            tabs: workspace.tabs.map { session in
                guard let pending = pendingTabs[session.id],
                      session.surfaceTree.isEmpty else {
                    return tab(from: session)
                }
                return TabSnapshot(
                    id: pending.id,
                    titleOverride: session.titleOverride.map(truncatedToStringLimit),
                    tabColor: session.tabColor.map(truncatedToStringLimit),
                    paneTree: pending.paneTree,
                    focusedPaneID: pending.focusedPaneID,
                    zoomedPaneID: pending.zoomedPaneID
                )
            },
            selectedTabID: workspace.selectedTabID
        )
    }

    // MARK: - Value → live

    /// Returns an empty tree for a missing snapshot. A declined or failed leaf
    /// rejects the entire tree, releasing every view built for that attempt.
    static func surfaceTree(
        from snapshot: PaneTreeSnapshot?,
        zoomedPaneID: UUID? = nil,
        makeSurface: SurfaceFactory
    ) -> SplitTree<Ghostty.SurfaceView>? {
        guard let snapshot else { return SplitTree<Ghostty.SurfaceView>() }
        guard let root = node(from: snapshot, makeSurface: makeSurface) else { return nil }

        let zoomed: SplitTree<Ghostty.SurfaceView>.Node?
        if let zoomedPaneID {
            zoomed = root.find(id: zoomedPaneID)
        } else {
            zoomed = nil
        }

        return SplitTree<Ghostty.SurfaceView>(root: root, zoomed: zoomed)
    }

    private static func node(
        from snapshot: PaneTreeSnapshot,
        makeSurface: SurfaceFactory
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch snapshot {
        case .leaf(let leaf):
            guard let view = makeSurface(leaf), view.error == nil else { return nil }
            if let title = leaf.title, !title.isEmpty {
                // Restored titles must be synchronous so an immediate save
                // does not erase them. Shell titles keep `setTitle` coalescing.
                view.restoreTitle(title)
            }
            return .leaf(view: view)

        case .split(let direction, let ratio, let left, let right):
            guard let leftNode = node(from: left, makeSurface: makeSurface),
                  let rightNode = node(from: right, makeSurface: makeSurface) else {
                return nil
            }
            return .split(.init(
                direction: self.direction(from: direction),
                ratio: ratio,
                left: leftNode,
                right: rightNode
            ))
        }
    }

    // MARK: - Direction mapping

    static func direction(from direction: SplitTree<Ghostty.SurfaceView>.Direction) -> PaneSplitDirection {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }

    static func direction(from direction: PaneSplitDirection) -> SplitTree<Ghostty.SurfaceView>.Direction {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}
