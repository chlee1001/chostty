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
struct AppSessionSnapshot: Codable, Equatable, Sendable {
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
struct WindowSnapshot: Codable, Equatable, Sendable {
    /// `BaseTerminalController.physicalUUID`: window identity and sort key.
    let physicalUUID: UUID

    let selection: SelectionSnapshot?
    let workspaces: [WorkspaceSnapshot]
}

/// Value form of `Selection` (workspace + tab).
struct SelectionSnapshot: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let tabID: UUID
}

/// Value form of `WorkspaceSession`.
struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let name: String

    /// `TerminalTabColor` encodes as its `Int` raw value, so the cases are
    /// positional: inserting one in the middle repaints every stored workspace.
    let color: TerminalTabColor

    let isCollapsed: Bool
    let defaultDirectory: String?
    let tabs: [TabSnapshot]
    let selectedTabID: UUID?
}

/// Value form of one virtual tab (`TerminalSessionState`).
struct TabSnapshot: Codable, Equatable, Sendable {
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
}

/// Split axis.
///
/// Deliberately not `SplitTree<Ghostty.SurfaceView>.Direction`: reusing that
/// would tie the on-disk format to the derived `Codable` of a type
/// parameterized on `NSView`, where a later case or `CodingKeys` change would
/// quietly invalidate stored files.
enum PaneSplitDirection: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// Value form of a pane tree.
indirect enum PaneTreeSnapshot: Codable, Equatable, Sendable {
    case leaf(PaneLeafSnapshot)
    case split(direction: PaneSplitDirection, ratio: Double, left: PaneTreeSnapshot, right: PaneTreeSnapshot)
}

/// Value form of a single pane.
struct PaneLeafSnapshot: Codable, Equatable, Sendable {
    /// Matches `Ghostty.SurfaceView.id`.
    let uuid: UUID

    /// Working directory reported by the PTY. May no longer exist when it is
    /// read back; hydration checks it.
    let cwd: String?

    /// Title at capture time. Applied after hydration through `setTitle(_:)`
    /// and then replaced by the new shell's own first title, so it never
    /// impersonates the old process.
    let title: String?

    /// SSH host identity and display-only destination. Runtime launch state
    /// and credentials deliberately remain outside the session file.
    let ssh: PaneSSHSnapshot?
}

/// Persisted subset of ``SSHPaneBinding``.
struct PaneSSHSnapshot: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case managed
        case sshConfig
    }

    let kind: Kind
    let hostID: UUID?
    let alias: String
    let displayDestination: String?
}

extension PaneLeafSnapshot {
    private enum CodingKeys: String, CodingKey {
        case uuid, cwd, title, ssh
    }

    /// A corrupt SSH binding must not discard the local pane layout.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        ssh = (try? container.decodeIfPresent(PaneSSHSnapshot.self, forKey: .ssh))
            .flatMap { $0 }
    }
}

extension PaneSSHSnapshot {
    private enum CodingKeys: String, CodingKey {
        case kind, hostID, alias, displayDestination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let hostID = try container.decodeIfPresent(UUID.self, forKey: .hostID)
        let alias = try container.decode(String.self, forKey: .alias)
        let displayDestination = try container.decodeIfPresent(String.self, forKey: .displayDestination)

        guard Self.isValid(
            kind: kind,
            hostID: hostID,
            alias: alias,
            displayDestination: displayDestination
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .alias,
                in: container,
                debugDescription: "Invalid SSH pane snapshot"
            )
        }

        self.kind = kind
        self.hostID = hostID
        self.alias = alias
        self.displayDestination = displayDestination
    }

    /// Returns `nil` rather than allowing an invalid live binding into a
    /// snapshot.
    init?(binding: SSHPaneBinding) {
        let (kind, hostID): (Kind, UUID?)
        switch binding.reference.source {
        case .managed(let value):
            kind = .managed
            hostID = value
        case .sshConfig:
            kind = .sshConfig
            hostID = nil
        }

        guard Self.isValid(
            kind: kind,
            hostID: hostID,
            alias: binding.reference.alias,
            displayDestination: binding.displayDestination
        ) else {
            return nil
        }

        self.kind = kind
        self.hostID = hostID
        alias = binding.reference.alias
        displayDestination = binding.displayDestination
    }

    /// Returns `nil` for a malformed manually-created snapshot.
    var binding: SSHPaneBinding? {
        guard Self.isValid(
            kind: kind,
            hostID: hostID,
            alias: alias,
            displayDestination: displayDestination
        ) else {
            return nil
        }

        let source: SSHHostSource
        switch kind {
        case .managed:
            guard let hostID else { return nil }
            source = .managed(hostID: hostID)
        case .sshConfig:
            source = .sshConfig
        }
        return SSHPaneBinding(
            reference: SSHHostReference(source: source, alias: alias),
            displayDestination: displayDestination
        )
    }

    private static func isValid(
        kind: Kind,
        hostID: UUID?,
        alias: String,
        displayDestination: String?
    ) -> Bool {
        guard case .success = SSHAlias.validate(alias),
              alias.utf8.count <= SessionSnapshotValidator.Limits.stringLength,
              (displayDestination?.utf8.count ?? 0) <= SessionSnapshotValidator.Limits.stringLength else {
            return false
        }
        switch kind {
        case .managed:
            return hostID != nil
        case .sshConfig:
            return hostID == nil
        }
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
