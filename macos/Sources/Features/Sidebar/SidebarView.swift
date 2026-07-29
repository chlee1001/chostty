import AppKit
import SwiftUI
import os

// MARK: - Git helpers

/// Resolve the current git branch name for a directory by walking up to the
/// nearest `.git`. Returns the short branch name, a detached-HEAD prefix, or
/// nil if the path is not inside a git work tree.
enum GitBranchResolver {
    /// Test-only call counter, incremented at the top of `branch(for:)`. This
    /// is the counting seam F6 requires to prove the sidebar filter's typing
    /// path never calls this synchronous filesystem walk.
    ///
    /// Guarded by an `OSAllocatedUnfairLock`: `branch(for:)` runs on
    /// `DispatchQueue.global` (see `GitMetadataService`), so an unsynchronized
    /// mutable static here would be a real data race — a Swift 6 concurrency
    /// error and a source of flaky counts under parallel test execution.
    private static let callCountLock = OSAllocatedUnfairLock(initialState: 0)

    static var callCount: Int {
        callCountLock.withLock { $0 }
    }

    static func branch(for pwd: String?) -> String? {
        callCountLock.withLock { $0 += 1 }
        guard let pwd, !pwd.isEmpty else { return nil }
        var url = URL(fileURLWithPath: pwd)
        let fm = FileManager.default
        repeat {
            let gitURL = url.appendingPathComponent(".git")
            let headPath = gitURL.appendingPathComponent("HEAD")
            if fm.fileExists(atPath: headPath.path) {
                return parseHEAD(at: headPath)
            }
            if fm.fileExists(atPath: gitURL.path) {
                if let gitdir = try? String(contentsOf: gitURL, encoding: .utf8) {
                    let trimmed = gitdir.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = trimmed.hasPrefix("gitdir: ")
                        ? String(trimmed.dropFirst("gitdir: ".count))
                        : trimmed
                    let realHead = URL(fileURLWithPath: resolved).appendingPathComponent("HEAD")
                    if fm.fileExists(atPath: realHead.path) {
                        return parseHEAD(at: realHead)
                    }
                }
            }
            url = url.deletingLastPathComponent()
        } while url.path != "/" && url.path != url.deletingLastPathComponent().path
        return nil
    }

    private static func parseHEAD(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if head.hasPrefix(prefix) {
            return String(head.dropFirst(prefix.count))
        }
        return String(head.prefix(7))
    }
}

// MARK: - Sidebar

/// A cmux-style left sidebar showing the workspace → tab hierarchy.
/// Workspaces are `WorkspaceSession`s owned by a `WorkspaceSessionStore`; tabs
/// are virtual tabs (`TerminalSessionState`) inside one physical window, not
/// separate AppKit windows or native tab groups. Clicking a tab switches
/// which session is presented in the owning window.
struct SidebarView: View {
    /// The per-controller workspace session store. Nonoptional per DR-1/Phase 1:
    /// every controller receives a fully-initialized store before presentation.
    @ObservedObject private var workspaceSessionStore: WorkspaceSessionStore

    /// Called when the user requests to toggle the sidebar visibility.
    let onToggle: () -> Void

    /// Called when the user requests a new workspace.
    var onNewWorkspace: () -> Void = {}

    /// Called when the user selects a workspace/tab. The owning controller
    /// drives the stage→commit transaction.
    var onSelectTab: (UUID, UUID) -> Void

    /// Called when the user closes a tab.
    var onCloseTab: ((UUID) -> Void)? = nil

    /// Called when the user closes a workspace.
    var onCloseWorkspace: ((UUID) -> Void)? = nil
    /// Called when the user picks "Reopen Closed Tab" from the F11 empty-area
    /// context menu. The owning controller resolves `ClosedTabHistory`;
    /// presentation never touches it directly.
    var onReopenClosedTab: () -> Void = {}

    /// F6: the sidebar search/filter query. Private view state — filtering is
    /// presentation-only and never reaches the store.
    @State private var filterText: String = ""

    /// Mirrors `WorkspaceSessionList`'s key so the header menu shows and
    /// toggles the same policy the list renders from.
    @AppStorage("SidebarSingleWorkspacePolicy") private var singleWorkspacePolicyRaw: String =
        SidebarSingleWorkspacePolicy.alwaysGrouped.rawValue

    private var singleWorkspacePolicy: SidebarSingleWorkspacePolicy {
        SidebarSingleWorkspacePolicy(rawValue: singleWorkspacePolicyRaw) ?? .alwaysGrouped
    }


    init(
        workspaceSessionStore: WorkspaceSessionStore,
        onToggle: @escaping () -> Void,
        onNewWorkspace: @escaping () -> Void = {},
        onSelectTab: @escaping (UUID, UUID) -> Void,
        onCloseTab: ((UUID) -> Void)? = nil,
        onCloseWorkspace: ((UUID) -> Void)? = nil,
        onReopenClosedTab: @escaping () -> Void = {}
    ) {
        self.workspaceSessionStore = workspaceSessionStore
        self.onToggle = onToggle
        self.onNewWorkspace = onNewWorkspace
        self.onSelectTab = onSelectTab
        self.onCloseTab = onCloseTab
        self.onCloseWorkspace = onCloseWorkspace
        self.onReopenClosedTab = onReopenClosedTab
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            filterField

            Divider()

            WorkspaceSessionList(
                store: workspaceSessionStore,
                onSelectTab: onSelectTab,
                onCloseTab: onCloseTab,
                onCloseWorkspace: onCloseWorkspace,
                onNewWorkspace: onNewWorkspace,
                onReopenClosedTab: onReopenClosedTab,
                filterQuery: filterText
            )
        }
        .background(.thickMaterial)
    }
    // MARK: Subviews

    private var header: some View {
        HStack {
            Text("Workspaces")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            let tabCount = workspaceSessionStore.snapshot.workspaces.reduce(0) { $0 + $1.tabs.count }
            Text("\(workspaceSessionStore.snapshot.workspaces.count)·\(tabCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button(action: { onNewWorkspace() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New workspace")
            // Workspace actions. Lives in the header rather than on its own
            // full-width row above the list, which cost a whole row of
            // vertical space for one right-aligned glyph.
            Menu {
                WorkspaceActionsMenuItems(
                    store: workspaceSessionStore,
                    isFlattened: workspaceSessionStore.snapshot.workspaces.count == 1
                        && singleWorkspacePolicy == .flatten,
                    singleWorkspacePolicy: singleWorkspacePolicy,
                    onNewWorkspace: onNewWorkspace,
                    onReopenClosedTab: onReopenClosedTab,
                    onTogglePolicy: {
                        singleWorkspacePolicyRaw = (singleWorkspacePolicy == .flatten
                            ? SidebarSingleWorkspacePolicy.alwaysGrouped
                            : .flatten).rawValue
                    })
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Workspace actions")
            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide sidebar (⌘B)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    /// F6: filters the workspace/tab tree by name, title, titleOverride, or
    /// pwd. Purely a `filterText` binding — the pure `SidebarFilter.filter`
    /// and `SidebarFilter.effectiveCollapsed` run downstream in
    /// `WorkspaceSessionList`/`WorkspaceSessionRow`. An empty query keeps
    /// today's rendering unchanged, so this field never touches the store.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !filterText.isEmpty {
                Button(action: { filterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Resizable Divider

/// A draggable vertical divider that adjusts the sidebar width.
/// The width is persisted via the binding (backed by @AppStorage).
struct SidebarDivider: View {
    @Binding var width: Double

    @State private var dragStartWidth: Double = 0
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isDragging ? 0.25 : 0.1))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: 10)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartWidth = width
                                }
                                width = max(180, min(450, dragStartWidth + value.translation.width))
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
            )
    }
}

// MARK: - WorkspaceSessionList

/// Shows the workspace → tab hierarchy from a per-controller WorkspaceSessionStore.
/// Clicking a workspace/tab selects it via the owning controller's
/// `selectSession(workspaceID:tabID:)`.
struct WorkspaceSessionList: View {
    @ObservedObject var store: WorkspaceSessionStore
    var onSelectTab: (UUID, UUID) -> Void
    var onCloseTab: ((UUID) -> Void)? = nil
    var onCloseWorkspace: ((UUID) -> Void)? = nil
    var onNewWorkspace: () -> Void = {}
    var onReopenClosedTab: () -> Void = {}

    /// F6: search/filter query from the sidebar header. Empty means "show
    /// everything", reproducing pre-F6 rendering exactly.
    var filterQuery: String = ""

    /// F10: governs whether a lone workspace renders flattened (no header
    /// row/chevron) or always grouped. App-local — never added to the
    /// Ghostty config surface.
    @AppStorage("SidebarSingleWorkspacePolicy") private var singleWorkspacePolicyRaw: String =
        SidebarSingleWorkspacePolicy.alwaysGrouped.rawValue

    private var singleWorkspacePolicy: SidebarSingleWorkspacePolicy {
        SidebarSingleWorkspacePolicy(rawValue: singleWorkspacePolicyRaw) ?? .alwaysGrouped
    }

    private func toggleSingleWorkspacePolicy() {
        singleWorkspacePolicyRaw = singleWorkspacePolicy.toggled.rawValue
    }


    /// Row currently under the pointer during a drag, used to draw the
    /// insertion indicator.
    @State private var dropTarget: WorkspaceDragPayload?

    /// Workspaces after the F6 filter. An empty query returns
    /// `store.snapshot.workspaces` unchanged (same array, same order).
    private var visibleWorkspaces: [WorkspaceSession] {
        SidebarFilter.filter(workspaces: store.snapshot.workspaces, query: filterQuery)
    }

    private var isFlattened: Bool {
        SidebarPolicy.shouldFlatten(workspaceCount: store.snapshot.workspaces.count, policy: singleWorkspacePolicy)
    }

    private var isFilterActive: Bool {
        !filterQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        // F11: right-clicking blank space below the last row opens the
        // workspace menu.
        //
        // Blank space in a ScrollView belongs to no view, so there is nothing
        // to hit-test and a right-click there is simply dropped. Attaching the
        // menu to a `.background(...)` behind the ScrollView does not help
        // either: that layer sits behind the AppKit scroll view, which hit-
        // tests first and swallows the click. Both spellings look correctly
        // wired and are dead in the running app.
        //
        // So the content is stretched to at least the viewport height and the
        // menu is attached to the content. The blank region is then a real,
        // hit-testable part of the stack rather than a hole. `contentShape`
        // is required because a stack's hit area is otherwise only its
        // children, which is the same hole in a different place.
        //
        // Right-clicking a row still opens that row's menu: SwiftUI resolves
        // the innermost `contextMenu` covering the click, and only blank space
        // falls through to this one.
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleWorkspaces) { workspace in
                        WorkspaceSessionRow(
                            workspace: workspace,
                            store: store,
                            dropTarget: $dropTarget,
                            onSelectTab: onSelectTab,
                            onCloseTab: onCloseTab,
                            onCloseWorkspace: onCloseWorkspace,
                            onDrop: handleDrop,
                            filterQuery: filterQuery,
                            isFlattened: isFlattened,
                            singleWorkspacePolicy: singleWorkspacePolicy,
                            onTogglePolicy: toggleSingleWorkspacePolicy
                        )
                    }
                    if isFilterActive && visibleWorkspaces.isEmpty {
                        noMatchesPlaceholder
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                // `minHeight`, not `height`: a list longer than the viewport
                // must still scroll normally.
                .frame(
                    maxWidth: .infinity,
                    minHeight: proxy.size.height,
                    alignment: .top
                )
                .contentShape(Rectangle())
                // Deliberately no `onDrop(of:delegate:)` here: that API
                // deadlocks the XCTest host (see `WorkspaceDragDrop.swift`).
                .contextMenu {
                    emptyAreaMenuItems
                }
            }
        }
    }

    /// F6 empty-result affordance: a non-empty query that matches nothing
    /// renders this instead of a blank sidebar with no explanation.
    private var noMatchesPlaceholder: some View {
        Text("No matches")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    /// F11 items: New Workspace, Collapse All, Expand All, Reopen Closed Tab,
    /// and the F10 policy toggle. "Collapse All" reuses
    /// `collapseAllExceptSelected()` — the presented workspace must stay
    /// expanded per acceptance — so it is exactly one validated commit.
    ///
    /// F5/F10: when the single-workspace `flatten` policy hides the
    /// workspace header row (and with it Rename/Color/Default Directory),
    /// those commands move here so they stay reachable on a fresh install,
    /// which starts with exactly one workspace under the default policy.
    @ViewBuilder
    /// Forwards to the shared component so the background menu and the
    /// header menu can never drift apart.
    private var emptyAreaMenuItems: some View {
        WorkspaceActionsMenuItems(
            store: store,
            isFlattened: isFlattened,
            singleWorkspacePolicy: singleWorkspacePolicy,
            onNewWorkspace: onNewWorkspace,
            onReopenClosedTab: onReopenClosedTab,
            onTogglePolicy: toggleSingleWorkspacePolicy)
    }

    /// Presents an `NSAlert` with an inline text field for renaming the
    /// single flattened workspace. `isFlattened` hides the header row that
    /// normally hosts `InlineRenameField`, so there is nowhere else to put
    /// this control.
    private func renameFlattenedWorkspace(_ workspace: WorkspaceSession) {
        store.promptRenameWorkspace(workspace.id)
    }

    /// Resolves a drag/drop pair into the right store mutation.
    ///
    /// Dropping a tab onto a workspace header moves it into that workspace;
    /// dropping onto another tab reorders relative to it. Workspaces only
    /// reorder among themselves.
    private func handleDrop(source: WorkspaceDragPayload, target: WorkspaceDragPayload) {
        switch (source, target) {
        case let (.tab(moving), .tab(over)):
            guard let ws = store.snapshot.workspaces.first(where: { w in
                w.tabs.contains { $0.id == over }
            }), let index = ws.tabs.firstIndex(where: { $0.id == over }) else { return }
            store.moveTab(moving, toWorkspace: ws.id, at: index)

        case let (.tab(moving), .workspace(wsID)):
            // Append to the end of the target workspace.
            guard let ws = store.snapshot.workspaces.first(where: { $0.id == wsID })
            else { return }
            store.moveTab(moving, toWorkspace: wsID, at: ws.tabs.count)

        case let (.workspace(moving), .workspace(over)):
            guard let index = store.snapshot.workspaces.firstIndex(where: { $0.id == over })
            else { return }
            store.moveWorkspace(moving, to: index)

        case (.workspace, .tab):
            // Dropping a whole workspace onto a tab has no meaning.
            break
        }
    }
}

/// Presents an `NSOpenPanel` restricted to directories and returns the
/// chosen path, or `nil` on cancel. Shared by the per-row context menu and
/// the F11 empty-area (flattened) "Set/Change Default Directory…" commands
/// so there is exactly one place this dialog is built.
private func chooseDirectory(current: String?) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Set Default Directory"
    if let current {
        panel.directoryURL = URL(fileURLWithPath: current)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path
}

private struct WorkspaceSessionRow: View {
    let workspace: WorkspaceSession
    @ObservedObject var store: WorkspaceSessionStore
    @Binding var dropTarget: WorkspaceDragPayload?
    var onSelectTab: (UUID, UUID) -> Void
    var onCloseTab: ((UUID) -> Void)? = nil
    var onCloseWorkspace: ((UUID) -> Void)? = nil
    var onDrop: (WorkspaceDragPayload, WorkspaceDragPayload) -> Void

    /// F6: search/filter query, used only to compute `effectiveCollapsed`
    /// below. Never mutates `store` — an active filter auto-expands a
    /// collapsed workspace visually so a match inside it stays visible.
    var filterQuery: String = ""

    /// F10: when true (single workspace, `flatten` policy) this row renders
    /// its tabs at the top level with no header/chevron/close button.
    var isFlattened: Bool = false

    /// F10/P2: the current single-workspace policy and its toggle, mirrored
    /// into this row's own context menu so the policy toggle has a second
    /// route beyond the F11 empty-area background layer — a miss there
    /// previously left no way back to "Always Group Workspaces".
    var singleWorkspacePolicy: SidebarSingleWorkspacePolicy = .alwaysGrouped
    var onTogglePolicy: () -> Void = {}
    @State private var hover = false
    @State private var isRenaming = false
    @State private var draftName = ""

    private var isSelected: Bool {
        store.snapshot.selection.workspaceID == workspace.id
    }

    /// The workspace's own accent, falling back to the system accent for the
    /// selected workspace so an uncolored workspace still reads as active.
    private var accent: Color {
        workspace.color.swiftUIColor ?? .accentColor
    }

    private var isDropTarget: Bool {
        dropTarget == .workspace(workspace.id)
    }

    /// The header's visual collapse state. Presentation-only per F6: a
    /// filter query auto-expands a collapsed workspace so a buried match
    /// still renders, without ever calling `setWorkspaceCollapsed`.
    private var effectiveCollapsed: Bool {
        SidebarFilter.effectiveCollapsed(isCollapsed: workspace.isCollapsed, query: filterQuery)
    }

    /// Whether a filter is currently narrowing the list. While true, collapse
    /// controls are disabled: `effectiveCollapsed` is forced false, so a
    /// commit would be invisible.
    private var isFiltering: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if isFlattened {
            // F10: a lone workspace under the `flatten` policy renders its
            // tabs at the top level — no header row, no chevron, no
            // close-workspace button.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    TabSessionRow(
                        tab: tab,
                        store: store,
                        isSelected: workspace.selectedTabID == tab.id && isSelected,
                        dropTarget: $dropTarget,
                        onTap: { onSelectTab(workspace.id, tab.id) },
                        onClose: store.snapshot.workspaces.flatMap(\.tabs).count > 1 ? { onCloseTab?(tab.id) } : nil,
                        onDrop: onDrop
                    )
                }
            }
            .padding(.vertical, 2)
        } else {
        VStack(alignment: .leading, spacing: 2) {
            // Workspace header
            HStack(spacing: 6) {
                // Disclosure control. Its own hit area, so toggling collapse
                // does not also switch to the workspace.
                Button {
                    store.toggleWorkspaceCollapsed(workspace.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(effectiveCollapsed ? 0 : 90))
                        .frame(width: 10, height: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Disabled while filtering. `effectiveCollapsed` is forced
                // false by an active query, so both the rotation above and the
                // tab-visibility branch below stop tracking the real state —
                // a click would still commit a persisted flip of
                // `workspace.isCollapsed` with NOTHING changing on screen, and
                // clearing the filter would then reveal a collapse state the
                // user never knowingly chose. Forced expansion stays purely
                // visual, which is the whole point of `effectiveCollapsed`.
                .disabled(isFiltering)
                .help(isFiltering ? "Collapse is unavailable while filtering" : "")
                .accessibilityLabel(workspace.isCollapsed ? "Expand Workspace" : "Collapse Workspace")

                Circle()
                    .fill(isSelected ? accent : accent.opacity(0.4))
                    .frame(width: 7, height: 7)

                if isRenaming {
                    InlineRenameField(
                        text: $draftName,
                        onCommit: { name in
                            store.renameWorkspace(workspace.id, to: name)
                            isRenaming = false
                        },
                        onCancel: { isRenaming = false })
                } else {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Text("\(workspace.tabs.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)

                if let onCloseWorkspace, store.snapshot.workspaces.count > 1 {
                    // Always laid out, revealed on hover. Inserting it on hover
                    // would reflow the row just as the pointer arrives.
                    Button(action: { onCloseWorkspace(workspace.id) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hover ? 1 : 0)
                    .allowsHitTesting(hover)
                    .accessibilityLabel("Close Workspace")
                }
            }
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.18) : (hover ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Selecting a workspace row presents that workspace's
                // currently-selected (or first) tab via the controller.
                let tabID = workspace.selectedTabID ?? workspace.tabs.first?.id
                if let tabID {
                    onSelectTab(workspace.id, tabID)
                }
            }
            .onHover { hover = $0 }
            .workspaceReorderable(
                payload: .workspace(workspace.id),
                dropTarget: $dropTarget,
                onDrop: onDrop)
            .contextMenu {
                // Same reason as the chevron: while filtering this commit
                // would produce no visible change.
                Button(workspace.isCollapsed ? "Expand" : "Collapse") {
                    store.toggleWorkspaceCollapsed(workspace.id)
                }
                .disabled(isFiltering)
                Button("Collapse Others") { store.collapseAllExceptSelected() }
                Button("Expand All") { store.expandAll() }
                Divider()
                Button("Rename…") {
                    draftName = workspace.name
                    isRenaming = true
                }
                Menu("Color") {
                    TabColorMenuItems(current: workspace.color) { color in
                        store.setWorkspaceColor(workspace.id, to: color)
                    }
                }
                Button(workspace.defaultDirectory == nil
                       ? "Set Default Directory…"
                       : "Change Default Directory…") {
                    if let path = chooseDirectory(current: workspace.defaultDirectory) {
                        store.setWorkspaceDefaultDirectory(workspace.id, to: path)
                    }
                }
                if workspace.defaultDirectory != nil {
                    Button("Clear Default Directory") {
                        store.setWorkspaceDefaultDirectory(workspace.id, to: nil)
                    }
                }
                // P2: second route to the F10 policy toggle so a miss on the
                // F11 empty-area background layer is not the only way back.
                Divider()
                Button(singleWorkspacePolicy == .flatten
                       ? "Always Group Workspaces"
                       : "Flatten Single Workspace") {
                    onTogglePolicy()
                }
                if let onCloseWorkspace, store.snapshot.workspaces.count > 1 {
                    Divider()
                    Button("Close Workspace") { onCloseWorkspace(workspace.id) }
                }
            }

            // Tab list, hidden while the workspace is collapsed. The header
            // keeps showing the tab count so a collapsed workspace still says
            // how much it holds. F6's `effectiveCollapsed` overrides a true
            // user collapse while a filter query is active.
            if !effectiveCollapsed {
                ForEach(workspace.tabs) { tab in
                    TabSessionRow(
                        tab: tab,
                        store: store,
                        isSelected: workspace.selectedTabID == tab.id && isSelected,
                        dropTarget: $dropTarget,
                        onTap: { onSelectTab(workspace.id, tab.id) },
                        onClose: store.snapshot.workspaces.flatMap(\.tabs).count > 1 ? { onCloseTab?(tab.id) } : nil,
                        onDrop: onDrop
                    )
                }
            }
        }
        // Tints the whole workspace section — header plus its tabs — which is
        // what the workspace color is for.
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(workspace.color.swiftUIColor?.opacity(0.10) ?? .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isDropTarget ? Color.accentColor : .clear,
                    lineWidth: 2)
        )
        }
    }
}

private struct TabSessionRow: View {
    /// Observed, not a plain `let`: the store's `snapshot` publisher only fires
    /// on *structural* commits, so title/pwd/bell changes reach the sidebar
    /// exclusively through this session's own metadata publishers. Holding it
    /// as a `let` would freeze every row at its initial "👻" / nil values.
    @ObservedObject var tab: TerminalSessionState
    @ObservedObject var store: WorkspaceSessionStore
    let isSelected: Bool
    @Binding var dropTarget: WorkspaceDragPayload?
    let onTap: () -> Void
    var onClose: (() -> Void)? = nil
    var onDrop: (WorkspaceDragPayload, WorkspaceDragPayload) -> Void
    @State private var hover = false
    @State private var branch: String?
    @State private var isRenaming = false
    @State private var draftName = ""

    /// A renamed tab keeps its override; otherwise the terminal's own title.
    private var label: String {
        if let override = tab.titleOverride, !override.isEmpty { return override }
        return tab.title.isEmpty ? "Terminal" : tab.title
    }

    private var tint: Color? {
        TerminalTabColor.fromStored(tab.tabColor).swiftUIColor
    }

    private var isDropTarget: Bool {
        dropTarget == .tab(tab.id)
    }
    var body: some View {
        // Deliberately NOT a Button.
        //
        // Two problems with wrapping this in one: the close control is itself a
        // Button, and a Button nested in another Button's label makes AppKit's
        // hit-testing ambiguous so the row stops responding reliably. And with
        // `.buttonStyle(.plain)` only the drawn glyphs are hit-testable, so the
        // large empty area to the right of a short title was dead space.
        //
        // A plain container plus `.contentShape` makes the entire row rect
        // clickable, and the close Button is now a sibling rather than a child.
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    InlineRenameField(
                        text: $draftName,
                        onCommit: { name in
                            store.renameTab(tab.id, to: name)
                            isRenaming = false
                        },
                        onCancel: { isRenaming = false })
                } else {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 4) {
                    if let branch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8.5))
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let pwd = tab.pwd, !pwd.isEmpty {
                        Image(systemName: "folder")
                            .font(.system(size: 8.5))
                        Text((pwd as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                // The git branch resolves asynchronously and then replaces the
                // pwd line. Without a reserved height the row grows or shrinks
                // a few points once that lookup lands, which reads as the
                // sidebar shifting on its own after a click.
                .frame(minHeight: 13, alignment: .leading)
            }

            Spacer(minLength: 0)

            // Reserved at all times. Inserting the bell only while it is
            // ringing reflows the row, so a tab that starts/stops ringing
            // would shove the close button sideways under the pointer.
            Image(systemName: "bell.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .opacity(tab.bell ? 1 : 0)

            if let onClose {
                // Always laid out, only revealed on hover. Inserting it on
                // hover instead would reflow the row exactly as the pointer
                // approaches, making it hard to actually hit.
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                .accessibilityLabel("Close Tab")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.leading, 18)
        .onHover { hover = $0 }
        .workspaceReorderable(
            payload: .tab(tab.id),
            dropTarget: $dropTarget,
            onDrop: onDrop)
        .contextMenu {
            Button("Rename…") {
                draftName = label
                isRenaming = true
            }
            if tab.titleOverride != nil {
                Button("Reset Name") { store.renameTab(tab.id, to: "") }
            }
            Menu("Color") {
                TabColorMenuItems(current: .fromStored(tab.tabColor)) { color in
                    store.setTabColor(tab.id, to: color)
                }
            }
            if let onClose {
                Divider()
                Button("Close Tab") { onClose() }
            }
        }
        .task(id: tab.pwd) {
            guard let pwd = tab.pwd, !pwd.isEmpty else {
                branch = nil
                return
            }
            branch = await GitMetadataService.shared.branch(forPwd: pwd)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        // A user-assigned tab color takes over the row fill; otherwise fall
        // back to the accent for selection and a neutral wash for hover.
        if isSelected {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill((tint ?? .accentColor).opacity(0.18))
        } else if let tint {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(hover ? 0.16 : 0.10))
        } else if hover {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        } else {
            Color.clear
        }
    }
}

/// The workspace-actions menu, shared by the sidebar header's `⋯` button and
/// the list's empty-area context menu. One definition so the two routes cannot
/// drift; the header route also guarantees reachability when a full tab list
/// leaves no blank space to right-click.
struct WorkspaceActionsMenuItems: View {
    @ObservedObject var store: WorkspaceSessionStore
    let isFlattened: Bool
    let singleWorkspacePolicy: SidebarSingleWorkspacePolicy
    let onNewWorkspace: () -> Void
    let onReopenClosedTab: () -> Void
    let onTogglePolicy: () -> Void

    /// Same NSAlert flow the sidebar's flattened row uses.
    private func renameWorkspacePrompt(_ workspace: WorkspaceSession) {
        store.promptRenameWorkspace(workspace.id)
    }

    @ViewBuilder
    var body: some View {
        Button("New Workspace") { onNewWorkspace() }
        Button("Collapse All") { store.collapseAllExceptSelected() }
        Button("Expand All") { store.expandAll() }
        Button("Reopen Closed Tab") { onReopenClosedTab() }
        Divider()
        Button(singleWorkspacePolicy == .flatten
               ? "Always Group Workspaces"
               : "Flatten Single Workspace") {
            onTogglePolicy()
        }
        if isFlattened, let workspace = store.snapshot.workspaces.first {
            Divider()
            Button("Rename…") { renameWorkspacePrompt(workspace) }
            Menu("Color") {
                TabColorMenuItems(current: workspace.color) { color in
                    store.setWorkspaceColor(workspace.id, to: color)
                }
            }
            Button(workspace.defaultDirectory == nil
                   ? "Set Default Directory…"
                   : "Change Default Directory…") {
                if let path = chooseDirectory(current: workspace.defaultDirectory) {
                    store.setWorkspaceDefaultDirectory(workspace.id, to: path)
                }
            }
            if workspace.defaultDirectory != nil {
                Button("Clear Default Directory") {
                    store.setWorkspaceDefaultDirectory(workspace.id, to: nil)
                }
            }
        }
    }
}
