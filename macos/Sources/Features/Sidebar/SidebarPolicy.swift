import Foundation

/// Whether a lone workspace renders flattened (no header row/chevron,
/// tabs at the top level) or always grouped. Governed by an app-local
/// `@AppStorage` key (`SidebarSingleWorkspacePolicy`) so nothing is added to
/// the Ghostty config surface.
///
/// `alwaysGrouped` is the DEFAULT: hiding the header for a lone workspace also
/// hides its name, colour dot, tab count and its whole context menu, so a new
/// user could not tell the workspace layer existed at all. Flattening stays
/// available for anyone who wants the extra row back.
enum SidebarSingleWorkspacePolicy: String, CaseIterable {
    case flatten
    case alwaysGrouped

    /// The other policy value, for a simple toggle menu item.
    var toggled: SidebarSingleWorkspacePolicy {
        self == .flatten ? .alwaysGrouped : .flatten
    }
}

/// Pure predicate deciding flattened vs. grouped sidebar rendering.
enum SidebarPolicy {
    /// True only for exactly one workspace under the `flatten` policy. Two or
    /// more workspaces (or the `alwaysGrouped` policy) always render grouped,
    /// reproducing today's rendering exactly.
    static func shouldFlatten(workspaceCount: Int, policy: SidebarSingleWorkspacePolicy) -> Bool {
        policy == .flatten && workspaceCount == 1
    }
}
