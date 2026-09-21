import AppKit
import SwiftUI

// MARK: - Placement

/// Where a window renders the workspace controls: the sidebar toggle and
/// workspace actions menu.
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
    var filesPanelController: FilesPanelController? = nil

    /// The same key `TerminalView` binds, so toggling from any host moves the
    /// same sidebar.
    @AppStorage("chostty.sidebarVisible") private var sidebarVisible: Bool = true

    /// Read here as well as in the list so the menu item toggles the same
    /// policy the sidebar renders from.
    @AppStorage("SidebarSingleWorkspacePolicy") private var singleWorkspacePolicyRaw: String =
        SidebarSingleWorkspacePolicy.alwaysGrouped.rawValue

    @State private var sidebarSyncInspection: SessionPersistenceController.SidebarSyncInspection?
    @State private var showingSidebarSync = false

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

            if let filesPanelController {
                FilesPanelToggleButton(controller: filesPanelController)
            }

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
                Divider()
                Button("Check Sidebar Sync…") {
                    refreshSidebarSync()
                    showingSidebarSync = true
                }
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
        .sheet(isPresented: $showingSidebarSync) {
            SidebarSyncSheet(
                inspection: sidebarSyncInspection,
                refresh: refreshSidebarSync,
                saveCurrentState: synchronizeSidebarState
            )
        }
    }

    private func refreshSidebarSync() {
        sidebarSyncInspection = (NSApp.delegate as? AppDelegate)?
            .sessionPersistence?
            .sidebarSyncInspection()
    }

    private func synchronizeSidebarState() {
        sidebarSyncInspection = (NSApp.delegate as? AppDelegate)?
            .sessionPersistence?
            .synchronizeSidebarState()
    }
}

private struct SidebarSyncSheet: View {
    let inspection: SessionPersistenceController.SidebarSyncInspection?
    let refresh: () -> Void
    let saveCurrentState: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sidebar Sync")
                .font(.headline)

            if let inspection {
                Text(statusText(for: inspection.status))
                    .font(.subheadline)
                    .foregroundStyle(statusColor(for: inspection.status))

                HStack(alignment: .top, spacing: 20) {
                    SidebarSyncSnapshotOutline(title: "Current", snapshot: inspection.current)
                    SidebarSyncSnapshotOutline(title: "Saved", snapshot: inspection.saved)
                }

                if inspection.canSynchronize {
                    Text("Saving writes the current live state to session storage. It never changes live terminals.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(unavailableText(for: inspection.synchronizationAvailability))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Refresh", action: refresh)
                    Spacer()
                    Button("Close") { dismiss() }
                    if inspection.canSynchronize {
                        Button("Save Current State", action: saveCurrentState)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("Session persistence is unavailable because the app state has not finished initializing.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 580)
    }

    private func statusText(for status: SessionPersistenceController.SidebarSyncInspection.Status) -> String {
        switch status {
        case .synchronized:
            return "Synchronized: the current and saved workspace graphs match."
        case .outOfSync:
            return "Out of sync: the saved workspace graph differs from the current state."
        case .absent:
            return "No saved session is available."
        case .unusable(let reason):
            return "The saved session is unusable: \(reason)"
        case .liveStateUnavailable:
            return "The current live session state is unavailable."
        }
    }

    private func statusColor(for status: SessionPersistenceController.SidebarSyncInspection.Status) -> Color {
        switch status {
        case .synchronized:
            return .green
        case .outOfSync, .absent, .unusable, .liveStateUnavailable:
            return .secondary
        }
    }

    private func unavailableText(
        for availability: SessionPersistenceController.SidebarSyncInspection.SynchronizationAvailability
    ) -> String {
        switch availability {
        case .available:
            return ""
        case .persistenceDisabled:
            return "Saving is unavailable because session persistence is disabled."
        case .ownedByAnotherLiveInstance:
            return "Saving is unavailable because another live app instance owns the saved session."
        case .noLiveState:
            return "Saving is unavailable because there are no live terminal windows."
        }
    }
}

private struct SidebarSyncSnapshotOutline: View {
    let title: String
    let snapshot: AppSessionSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if let snapshot {
                        if snapshot.windows.count > 1 {
                            ForEach(Array(snapshot.windows.enumerated()), id: \.element.physicalUUID) { index, window in
                                Text("Window \(index + 1)")
                                    .font(.footnote.weight(.semibold))
                                workspaceOutline(for: window)
                                    .padding(.leading, 12)
                            }
                        } else if let window = snapshot.windows.first {
                            workspaceOutline(for: window)
                        }
                    } else {
                        Text("Unavailable")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func workspaceOutline(for window: WindowSnapshot) -> some View {
        ForEach(window.workspaces, id: \.id) { workspace in
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .font(.footnote.weight(.semibold))
                ForEach(workspace.tabs, id: \.id) { tab in
                    Text(tabSummary(tab))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12)
        }
    }

    private func tabDisplayLabel(_ tab: TabSnapshot) -> String {
        let override = tab.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        let paneTitle = tab.paneTree?.leaves.first?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return paneTitle.isEmpty ? "Terminal" : paneTitle
    }

    private func tabSummary(_ tab: TabSnapshot) -> String {
        let paneCount = tab.paneTree?.paneCount ?? 0
        return "\(tabDisplayLabel(tab)) — \(paneCount) \(paneCount == 1 ? "pane" : "panes")"
    }
}

private struct FilesPanelToggleButton: View {
    @ObservedObject var controller: FilesPanelController

    var body: some View {
        Button(action: controller.toggleVisible) {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(.plain)
        .help(controller.presentation.visible ? "Hide Files Panel" : "Show Files Panel")
        .accessibilityLabel(controller.presentation.visible ? "Hide Files Panel" : "Show Files Panel")
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
    var filesPanelController: FilesPanelController? = nil

    /// One standard titlebar height, so the strip stands in for the titlebar
    /// rather than reading as an extra band of content.
    private static let height: Double = 28

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceControls(
                store: store,
                onNewWorkspace: onNewWorkspace,
                onReopenClosedTab: onReopenClosedTab,
                filesPanelController: filesPanelController)

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
