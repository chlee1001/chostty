import Foundation

/// Pure, presentation-only sidebar search/filter.
///
/// Scope is GLOBAL over `WorkspaceSession.name` and each tab's `title`,
/// `titleOverride`, and `pwd`. Git-branch matching is deliberately DESCOPED:
/// `GitMetadataService`'s cache is actor-isolated and private, and resolved
/// branches live in each row's own `@State`, so a MainActor pwd-to-branch
/// index would be real new architecture rather than a Phase-4 presentation
/// change. `GitBranchResolver.branch(for:)` — the synchronous filesystem
/// walk — is never called from this type or from anything on the typing
/// path; see `GitBranchResolver.callCount` for the test-facing proof.
enum SidebarFilter {
    /// Returns the subset of `workspaces` matching `query`, or `workspaces`
    /// unchanged when `query` is empty (or all whitespace) — reproducing
    /// today's rendering exactly.
    ///
    /// A workspace matches when its own name matches, or any of its tabs
    /// match (by title, titleOverride, or pwd). Matching workspaces keep
    /// their full tab list; tabs are not individually filtered out.
    static func filter(workspaces: [WorkspaceSession], query: String) -> [WorkspaceSession] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return workspaces }
        return workspaces.filter { matches(workspace: $0, needle: needle) }
    }

    /// The sidebar row's rendered collapse state. A workspace the user
    /// collapsed still renders its tabs while a filter query is active, so a
    /// match buried inside it is visible — but this is VISUAL ONLY. Callers
    /// MUST NOT feed this back into `WorkspaceSessionStore.setWorkspaceCollapsed`;
    /// doing so from a view read would mutate the store during render and
    /// destroy the user's actual collapse state.
    static func effectiveCollapsed(isCollapsed: Bool, query: String) -> Bool {
        isCollapsed && normalized(query).isEmpty
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(workspace: WorkspaceSession, needle: String) -> Bool {
        if workspace.name.lowercased().contains(needle) { return true }
        return workspace.tabs.contains { matches(tab: $0, needle: needle) }
    }

    private static func matches(tab: TerminalSessionState, needle: String) -> Bool {
        if tab.title.lowercased().contains(needle) { return true }
        if let override = tab.titleOverride, override.lowercased().contains(needle) { return true }
        if let pwd = tab.pwd, pwd.lowercased().contains(needle) { return true }
        return false
    }
}
