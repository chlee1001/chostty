import Foundation

/// Shared value checks applied before saving and before a decoded snapshot
/// reaches the live graph.
///
/// This exists because `WorkspaceSessionStore.init(restoredWorkspaces:selection:)`
/// defends its invariants with `precondition`, not optionals. The session file
/// is an ordinary file a user can edit, so an empty workspace list would
/// otherwise take the process down during launch - the one moment the
/// crash-loop marker cannot help, since it is cleared only after a successful
/// boot.
///
/// Identity and resource violations reject the whole file; a selection pointing
/// at something that no longer exists is clamped, because losing which tab was
/// focused is not a reason to throw away the layout.
enum SessionSnapshotValidator {
    /// Shared resource bounds for live projections and decoded files.
    enum Limits {
        static let windows = 12
        static let workspacesPerWindow = 128
        static let panesPerWorkspace = 512
        static let paneTreeDepth = 32
        /// Generous next to a real path or title, small enough that a
        /// hand-edited file cannot become a memory bomb.
        static let stringLength = 4096
    }

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case schemaVersion(found: Int, expected: Int)
        case noWindows
        case windowWithoutWorkspaces(windowID: UUID)
        case workspaceWithoutTabs(workspaceID: UUID)
        case duplicateIdentifier(UUID)
        case paneTreeTooDeep(tabID: UUID, depth: Int)
        case limitExceeded(kind: String, count: Int, limit: Int)
        case invalidSplitRatio(Double)
        case stringTooLong(field: String, length: Int)

        var description: String {
            switch self {
            case .schemaVersion(let found, let expected):
                return "schemaVersion got=\(found) want=\(expected)"
            case .noWindows:
                return "noWindows"
            case .windowWithoutWorkspaces(let id):
                return "windowWithoutWorkspaces window=\(id)"
            case .workspaceWithoutTabs(let id):
                return "workspaceWithoutTabs workspace=\(id)"
            case .duplicateIdentifier(let id):
                return "duplicateIdentifier id=\(id)"
            case .paneTreeTooDeep(let tabID, let depth):
                return "paneTreeTooDeep tab=\(tabID) depth=\(depth) limit=\(Limits.paneTreeDepth)"
            case .limitExceeded(let kind, let count, let limit):
                return "limitExceeded kind=\(kind) count=\(count) limit=\(limit)"
            case .invalidSplitRatio(let ratio):
                return "invalidSplitRatio ratio=\(ratio)"
            case .stringTooLong(let field, let length):
                return "stringTooLong field=\(field) length=\(length) limit=\(Limits.stringLength)"
            }
        }
    }

    /// - Returns: the snapshot to apply, with dangling selections clamped, or
    ///   the reason it cannot be applied.
    static func validate(_ snapshot: AppSessionSnapshot) -> Result<AppSessionSnapshot, Rejection> {
        guard snapshot.version == AppSessionSnapshot.currentVersion else {
            return .failure(.schemaVersion(found: snapshot.version, expected: AppSessionSnapshot.currentVersion))
        }
        guard !snapshot.windows.isEmpty else { return .failure(.noWindows) }
        guard snapshot.windows.count <= Limits.windows else {
            return .failure(.limitExceeded(kind: "window", count: snapshot.windows.count, limit: Limits.windows))
        }

        var seenIdentifiers = Set<UUID>()
        var clampedWindows: [WindowSnapshot] = []
        clampedWindows.reserveCapacity(snapshot.windows.count)

        for window in snapshot.windows {
            guard seenIdentifiers.insert(window.physicalUUID).inserted else {
                return .failure(.duplicateIdentifier(window.physicalUUID))
            }
            guard !window.workspaces.isEmpty else {
                return .failure(.windowWithoutWorkspaces(windowID: window.physicalUUID))
            }
            guard window.workspaces.count <= Limits.workspacesPerWindow else {
                return .failure(.limitExceeded(
                    kind: "workspace",
                    count: window.workspaces.count,
                    limit: Limits.workspacesPerWindow
                ))
            }

            var clampedWorkspaces: [WorkspaceSnapshot] = []
            clampedWorkspaces.reserveCapacity(window.workspaces.count)

            for workspace in window.workspaces {
                guard seenIdentifiers.insert(workspace.id).inserted else {
                    return .failure(.duplicateIdentifier(workspace.id))
                }
                guard !workspace.tabs.isEmpty else {
                    return .failure(.workspaceWithoutTabs(workspaceID: workspace.id))
                }
                if let rejection = checkLength(workspace.name, field: "workspace.name") {
                    return .failure(rejection)
                }
                if let rejection = checkLength(workspace.defaultDirectory, field: "workspace.defaultDirectory") {
                    return .failure(rejection)
                }
                guard workspace.paneCount <= Limits.panesPerWorkspace else {
                    return .failure(.limitExceeded(
                        kind: "pane",
                        count: workspace.paneCount,
                        limit: Limits.panesPerWorkspace
                    ))
                }

                for tab in workspace.tabs {
                    guard seenIdentifiers.insert(tab.id).inserted else {
                        return .failure(.duplicateIdentifier(tab.id))
                    }
                    if let rejection = checkLength(tab.titleOverride, field: "tab.titleOverride") {
                        return .failure(rejection)
                    }
                    if let rejection = checkLength(tab.tabColor, field: "tab.tabColor") {
                        return .failure(rejection)
                    }
                    if let tree = tab.paneTree {
                        let depth = tree.depth
                        guard depth <= Limits.paneTreeDepth else {
                            return .failure(.paneTreeTooDeep(tabID: tab.id, depth: depth))
                        }
                        if let rejection = checkRatios(tree) {
                            return .failure(rejection)
                        }
                        for leaf in tree.leaves {
                            guard seenIdentifiers.insert(leaf.uuid).inserted else {
                                return .failure(.duplicateIdentifier(leaf.uuid))
                            }
                            if let rejection = checkLength(leaf.cwd, field: "pane.cwd") {
                                return .failure(rejection)
                            }
                            if let rejection = checkLength(leaf.title, field: "pane.title") {
                                return .failure(rejection)
                            }
                        }
                    }
                }

                // Clamp: a selected tab that is gone falls back to the first
                // tab, which is guaranteed to exist by the check above.
                let tabIDs = Set(workspace.tabs.map(\.id))
                let selectedTabID = workspace.selectedTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
                    ?? workspace.tabs[0].id

                clampedWorkspaces.append(WorkspaceSnapshot(
                    id: workspace.id,
                    name: workspace.name,
                    color: workspace.color,
                    isCollapsed: workspace.isCollapsed,
                    defaultDirectory: workspace.defaultDirectory,
                    tabs: workspace.tabs,
                    selectedTabID: selectedTabID
                ))
            }

            // Clamp: the window selection must name a workspace that exists and
            // a tab inside that workspace. Anything else falls back to the
            // first workspace's selected tab.
            let selection = clampedSelection(window.selection, workspaces: clampedWorkspaces)

            clampedWindows.append(WindowSnapshot(
                physicalUUID: window.physicalUUID,
                selection: selection,
                workspaces: clampedWorkspaces
            ))
        }

        return .success(AppSessionSnapshot(
            version: snapshot.version,
            ownerInstanceID: snapshot.ownerInstanceID,
            ownerPID: snapshot.ownerPID,
            windows: clampedWindows
        ))
    }

    /// `Double` decodes `NaN`, infinities and out-of-range values happily, and
    /// they would reach the layout math as a divider that cannot be drawn.
    private static func checkRatios(_ tree: PaneTreeSnapshot) -> Rejection? {
        switch tree {
        case .leaf:
            return nil
        case .split(_, let ratio, let left, let right):
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                return .invalidSplitRatio(ratio)
            }
            return checkRatios(left) ?? checkRatios(right)
        }
    }

    private static func checkLength(_ value: String?, field: String) -> Rejection? {
        guard let value, value.utf8.count > Limits.stringLength else { return nil }
        return .stringTooLong(field: field, length: value.utf8.count)
    }

    private static func clampedSelection(
        _ selection: SelectionSnapshot?,
        workspaces: [WorkspaceSnapshot]
    ) -> SelectionSnapshot? {
        guard let first = workspaces.first else { return nil }

        if let selection,
           let workspace = workspaces.first(where: { $0.id == selection.workspaceID }),
           workspace.tabs.contains(where: { $0.id == selection.tabID }) {
            return selection
        }

        guard let tabID = first.selectedTabID ?? first.tabs.first?.id else { return nil }
        return SelectionSnapshot(workspaceID: first.id, tabID: tabID)
    }

}
