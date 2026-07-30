import AppKit
import SwiftUI

// MARK: - Placement

/// Where a window renders the workspace controls: the sidebar toggle, the new
/// workspace `+`, and the workspace actions menu.
///
/// They sit next to the traffic lights. Windows whose titlebar cannot show an
/// accessory fall back to one of the other two hosts.
enum WorkspaceControlsPlacement {
    /// A leading titlebar accessory, immediately right of the traffic lights.
    case titlebarAccessory

    /// A strip drawn along the top edge of the window content.
    ///
    /// Used when the window has no titlebar to put an accessory in: non-native
    /// fullscreen and `window-decorations = false` drop `.titled`, and native
    /// fullscreen keeps it but moves the titlebar into an auto-hiding overlay.
    case contentStrip

    /// Inline in the sidebar header.
    ///
    /// For the quick terminal, a borderless panel with no titlebar and no room
    /// for a strip, and for `macos-titlebar-style = hidden`, where a strip would
    /// hand back the window chrome that setting removes.
    case sidebarHeader
}

extension WorkspaceControlsPlacement {
    /// The placement for a standalone terminal window, derived from the window
    /// state that decides whether its titlebar can show an accessory.
    ///
    /// - Parameters:
    ///   - isTitled: `.titled` in the style mask. Non-native fullscreen and
    ///     `window-decorations = false` both drop it, and without it there is no
    ///     titlebar to attach an accessory to at all.
    ///   - isFullscreen: `.fullScreen` in the style mask. Native fullscreen keeps
    ///     `.titled` but moves the titlebar into an auto-hiding overlay, so an
    ///     accessory is invisible until the pointer reaches the top edge.
    ///   - titlebarStyle: `hidden` keeps `.titled` for the window frame but hides
    ///     the whole `NSTitlebarContainerView`, accessory included. That style
    ///     exists to remove window chrome, so the controls fall back into the
    ///     sidebar header rather than reintroducing a chrome row as a strip.
    static func forStandaloneWindow(
        isTitled: Bool,
        isFullscreen: Bool,
        titlebarStyle: Ghostty.Config.MacOSTitlebarStyle
    ) -> WorkspaceControlsPlacement {
        if !isTitled { return .contentStrip }
        if titlebarStyle == .hidden { return .sidebarHeader }
        if isFullscreen { return .contentStrip }
        return .titlebarAccessory
    }

    /// Whether the leading titlebar accessory may show the controls.
    ///
    /// True only for `.titlebarAccessory`. In native fullscreen the auto-hidden
    /// titlebar still slides down on hover, and a visible accessory there would
    /// duplicate the strip's buttons.
    var showsTitlebarAccessory: Bool { self == .titlebarAccessory }
}

// MARK: - Controls

/// The workspace control row. One view for all three placements, so the
/// buttons never differ between windowed, fullscreen and undecorated windows.
struct WorkspaceControls: View {
    @ObservedObject var store: WorkspaceSessionStore

    /// Both actions run through `TerminalCommandRouter` on the owning
    /// controller, so a click carries the same authority as `⌘N` / `⌘⇧T`.
    let onNewWorkspace: () -> Void
    let onReopenClosedTab: () -> Void

    /// The same key `TerminalView` binds, so toggling from any host moves the
    /// same sidebar.
    @AppStorage("chostty.sidebarVisible") private var sidebarVisible: Bool = true

    /// Read here as well as in the list so the menu item toggles the same
    /// policy the sidebar renders from.
    @AppStorage("SidebarSingleWorkspacePolicy") private var singleWorkspacePolicyRaw: String =
        SidebarSingleWorkspacePolicy.alwaysGrouped.rawValue

    private var singleWorkspacePolicy: SidebarSingleWorkspacePolicy {
        SidebarSingleWorkspacePolicy(rawValue: singleWorkspacePolicyRaw) ?? .alwaysGrouped
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { sidebarVisible.toggle() }) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(sidebarVisible ? "Hide sidebar (⌘B)" : "Show sidebar (⌘B)")
            .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")

            Button(action: onNewWorkspace) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New workspace (⌘N)")
            .accessibilityLabel("New Workspace")

            Menu {
                WorkspaceActionsMenuItems(
                    store: store,
                    isFlattened: SidebarPolicy.shouldFlatten(
                        workspaceCount: store.snapshot.workspaces.count,
                        policy: singleWorkspacePolicy),
                    singleWorkspacePolicy: singleWorkspacePolicy,
                    onNewWorkspace: onNewWorkspace,
                    onReopenClosedTab: onReopenClosedTab,
                    onTogglePolicy: {
                        singleWorkspacePolicyRaw = singleWorkspacePolicy.toggled.rawValue
                    })
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Workspace actions")
            .accessibilityLabel("Workspace Actions")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Content Strip

/// The `contentStrip` host: a titlebar row drawn at the top of the window
/// content when the real titlebar cannot host the controls.
///
/// It carries the window title too, since every case that selects this
/// placement leaves the system title hidden or gone.
struct WorkspaceControlsStrip: View {
    @ObservedObject var store: WorkspaceSessionStore
    let title: String
    let representedURL: URL?
    let onNewWorkspace: () -> Void
    let onReopenClosedTab: () -> Void

    /// One standard titlebar height, so the strip stands in for the titlebar
    /// rather than reading as an extra band of content.
    private static let height: Double = 28

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceControls(
                store: store,
                onNewWorkspace: onNewWorkspace,
                onReopenClosedTab: onReopenClosedTab)

            // Two spacers rather than a centering overlay: the title can never
            // land underneath the controls no matter how narrow the window is.
            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if let representedURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: representedURL.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
    }
}
