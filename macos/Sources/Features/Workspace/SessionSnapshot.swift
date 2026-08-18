import Foundation

// MARK: - Session snapshot value types
//
// The workspace, virtual tab and pane structure Chostty persists between
// launches, as plain values: no `NSView`, no `Ghostty.SurfaceView`, no
// reference into the live graph. Encoding can therefore run off the main
// thread, and tests can drive the whole layer without a PTY.
//
// Nothing here may carry a timestamp. The save path skips the write when the
// encoded bytes match the file on disk, so a per-encode value would make an
// idle app rewrite the file on every tick. The file's mtime already says when
// it was written.

/// Root document written to `session.json`.
struct AppSessionSnapshot: Codable, Equatable {
    /// A file whose version is not ``currentVersion`` is unusable, never
    /// partially applied.
    let version: Int

    /// Identifies the process that wrote this file. Issued once at launch.
    let ownerInstanceID: UUID

    /// PID of the writer, paired with ``ownerInstanceID`` so boot can tell
    /// "another live app owns this" from the far more common "this is my own
    /// previous launch".
    let ownerPID: Int32

    /// Ordered by ``WindowSnapshot/physicalUUID``, since `TerminalController.all`
    /// derives from `NSApplication.shared.windows` and that order is unstable.
    let windows: [WindowSnapshot]

    static let currentVersion = 1

    /// Stands in for owner fields that could not be read. Never matches a live
    /// process, so the file is treated as unowned and the next save replaces
    /// both values.
    static let unownedInstanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let unownedPID: Int32 = 0

    init(
        version: Int = AppSessionSnapshot.currentVersion,
        ownerInstanceID: UUID,
        ownerPID: Int32,
        windows: [WindowSnapshot]
    ) {
        self.version = version
        self.ownerInstanceID = ownerInstanceID
        self.ownerPID = ownerPID
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case version, ownerInstanceID, ownerPID, windows
    }

    /// `version` and `windows` fail closed; the owner fields do not.
    ///
    /// Owner bookkeeping only feeds the boot-time "is another live instance
    /// using this file" check, so losing it is not worth discarding an
    /// otherwise intact snapshot of the user's workspaces.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.windows = try container.decode([WindowSnapshot].self, forKey: .windows)
        self.ownerInstanceID = (try? container.decodeIfPresent(UUID.self, forKey: .ownerInstanceID))
            .flatMap { $0 } ?? AppSessionSnapshot.unownedInstanceID
        self.ownerPID = (try? container.decodeIfPresent(Int32.self, forKey: .ownerPID))
            .flatMap { $0 } ?? AppSessionSnapshot.unownedPID
    }
}

/// One physical `NSWindow` worth of structure.
struct WindowSnapshot: Codable, Equatable {
    /// `BaseTerminalController.physicalUUID`: window identity and sort key.
    let physicalUUID: UUID

    let selection: SelectionSnapshot?
    let workspaces: [WorkspaceSnapshot]

    init(physicalUUID: UUID, selection: SelectionSnapshot?, workspaces: [WorkspaceSnapshot]) {
        self.physicalUUID = physicalUUID
        self.selection = selection
        self.workspaces = workspaces
    }
}

/// Value form of `Selection` (workspace + tab).
struct SelectionSnapshot: Codable, Equatable {
    let workspaceID: UUID
    let tabID: UUID

    init(workspaceID: UUID, tabID: UUID) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

/// Value form of `WorkspaceSession`.
struct WorkspaceSnapshot: Codable, Equatable {
    let id: UUID
    let name: String

    /// `TerminalTabColor` encodes as its `Int` raw value, so the cases are
    /// positional: inserting one in the middle repaints every stored workspace.
    let color: TerminalTabColor

    let isCollapsed: Bool
    let defaultDirectory: String?
    let tabs: [TabSnapshot]
    let selectedTabID: UUID?

    init(
        id: UUID,
        name: String,
        color: TerminalTabColor,
        isCollapsed: Bool,
        defaultDirectory: String?,
        tabs: [TabSnapshot],
        selectedTabID: UUID?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.defaultDirectory = defaultDirectory
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }
}

/// Value form of one virtual tab (`TerminalSessionState`).
struct TabSnapshot: Codable, Equatable {
    let id: UUID

    /// User-supplied label. It survives the restart; it is not a claim about
    /// what the new shell is running.
    let titleOverride: String?

    /// `TerminalSessionState.tabColor`, distinct from the workspace-level
    /// ``WorkspaceSnapshot/color``.
    let tabColor: String?

    let paneTree: PaneTreeSnapshot?
    let focusedPaneID: UUID?

    /// `SplitTree.zoomed` by leaf UUID, so this layer never mirrors
    /// `SplitTree`'s path encoding.
    let zoomedPaneID: UUID?

    init(
        id: UUID,
        titleOverride: String?,
        tabColor: String?,
        paneTree: PaneTreeSnapshot?,
        focusedPaneID: UUID?,
        zoomedPaneID: UUID?
    ) {
        self.id = id
        self.titleOverride = titleOverride
        self.tabColor = tabColor
        self.paneTree = paneTree
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }
}

/// Split axis.
///
/// Deliberately not `SplitTree<Ghostty.SurfaceView>.Direction`: reusing that
/// would tie the on-disk format to the derived `Codable` of a type
/// parameterized on `NSView`, where a later case or `CodingKeys` change would
/// quietly invalidate stored files.
enum PaneSplitDirection: String, Codable, Equatable {
    case horizontal
    case vertical
}

/// Value form of a pane tree.
indirect enum PaneTreeSnapshot: Codable, Equatable {
    case leaf(PaneLeafSnapshot)
    case split(direction: PaneSplitDirection, ratio: Double, left: PaneTreeSnapshot, right: PaneTreeSnapshot)
}

/// Value form of a single pane.
struct PaneLeafSnapshot: Codable, Equatable {
    /// Matches `Ghostty.SurfaceView.id`.
    let uuid: UUID

    /// Working directory reported by the PTY. May no longer exist when it is
    /// read back; hydration checks it.
    let cwd: String?

    /// Title at capture time. Applied after hydration through `setTitle(_:)`
    /// and then replaced by the new shell's own first title, so it never
    /// impersonates the old process.
    let title: String?

    init(uuid: UUID, cwd: String?, title: String?) {
        self.uuid = uuid
        self.cwd = cwd
        self.title = title
    }
}

// MARK: - Convenience

extension PaneTreeSnapshot {
    var leaves: [PaneLeafSnapshot] {
        switch self {
        case .leaf(let leaf):
            return [leaf]
        case .split(_, _, let left, let right):
            return left.leaves + right.leaves
        }
    }

    var paneCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, _, let left, let right):
            return left.paneCount + right.paneCount
        }
    }

    /// Longest root-to-leaf depth; a lone leaf is 1. The load validator uses
    /// it to reject files that would recurse too far.
    var depth: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, _, let left, let right):
            return 1 + max(left.depth, right.depth)
        }
    }
}

extension WorkspaceSnapshot {
    var paneCount: Int {
        tabs.reduce(0) { $0 + ($1.paneTree?.paneCount ?? 0) }
    }
}
