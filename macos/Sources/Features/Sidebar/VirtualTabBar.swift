import SwiftUI

/// Horizontal tab strip for the virtual tabs of the selected workspace.
///
/// This is deliberately NOT an AppKit tab bar: native tabbing is disallowed
/// (`TerminalWindow.tabbingMode == .disallowed`) because every tab here is a
/// virtual tab inside one physical window. This view is purely a control
/// surface over `WorkspaceSessionStore`.
///
/// It hides itself when the selected workspace has a single tab, so a plain
/// one-tab window looks exactly like it did before.
/// Dedicated result type for `VirtualTabBar.tabItemWidth(availableWidth:tabCount:)`.
/// The fileprivate initializer means `.frame(width: itemWidth.points)` at the
/// item body can only ever be fed by that one function — not a literal, and
/// not a decoupled computation elsewhere in this file. Stronger than any
/// string-matching test, and free at runtime.
struct TabItemWidth {
    let points: CGFloat
    fileprivate init(points: CGFloat) {
        self.points = points
    }
}

struct VirtualTabBar: View {
    @ObservedObject var store: WorkspaceSessionStore

    /// Called when the user activates a tab.
    var onSelect: (UUID, UUID) -> Void

    /// Called when the user closes a tab.
    var onClose: (UUID) -> Void

    /// Called when the user picks "Close Other Tabs" from a tab's context menu.
    var onCloseOthers: (UUID) -> Void

    /// Called when the user picks "Close Tabs to the Right" from a tab's context menu.
    var onCloseToTheRight: (UUID) -> Void

    /// Called when a tab dragged in from ANOTHER window is dropped on the
    /// strip. The tab joins this window's selected workspace and becomes
    /// presented. Nil-accepting: same-window drops keep the reorder path.
    var onReceiveForeignTab: ((UUID) -> Bool)? = nil

    @State private var dropTarget: WorkspaceDragPayload?

    private var workspace: WorkspaceSession? {
        store.snapshot.workspaces.first { $0.id == store.snapshot.selection.workspaceID }
    }

    /// Fixed vertical height for the tab strip. `GeometryReader` (used
    /// below to size items) greedily claims all available space on both
    /// axes, so without an explicit height it would expand to fill the
    /// entire remaining window instead of sitting as a thin strip.
    private static let barHeight: CGFloat = 44

    /// Inter-item spacing, shared between the HStack and
    /// `tabItemWidth(availableWidth:tabCount:)` so the math stays in sync.
    private static let itemSpacing: CGFloat = 6

    /// Pure: the width of one tab item given the space available to the
    /// strip and how many tabs are showing. Available width minus the
    /// inter-item spacing, divided evenly among the tabs, clamped to
    /// `120...240` so a strip with many tabs stays legible and a strip with
    /// few tabs doesn't stretch absurdly wide.
    ///
    /// Returns a `TabItemWidth`, not a bare `CGFloat`: that dedicated type's
    /// only initializer is fileprivate to this file, so the item body's
    /// `.frame(width: itemWidth.points)` call site can only ever be satisfied
    /// by THIS function's result — not a literal, and not some decoupled
    /// computation a future edit might introduce. Stronger than any string
    /// match, and free at runtime.
    static func tabItemWidth(availableWidth: CGFloat, tabCount: Int) -> TabItemWidth {
        let count = max(1, tabCount)
        let usable = availableWidth - itemSpacing * CGFloat(count - 1)
        let raw = usable / CGFloat(count)
        return TabItemWidth(points: min(240, max(120, raw)))
    }

    var body: some View {
        if let workspace, workspace.tabs.count > 1 {
            ScrollViewReader { scrollProxy in
                GeometryReader { proxy in
                    VirtualTabBarStrip(
                        workspace: workspace,
                        store: store,
                        itemWidth: Self.tabItemWidth(
                            availableWidth: proxy.size.width,
                            tabCount: workspace.tabs.count),
                        spacing: Self.itemSpacing,
                        dropTarget: $dropTarget,
                        onSelect: onSelect,
                        onClose: onClose,
                        onCloseOthers: onCloseOthers,
                        onCloseToTheRight: onCloseToTheRight,
                        onDrop: { source, target in
                            handleDrop(source: source, target: target, in: workspace)
                        }
                    )
                    // GeometryReader positions its content at topLeading, so
                    // the strip sat at the top of the bar with dead space
                    // beneath it. Filling the reader lets the row centre.
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .onChange(of: store.snapshot.selection.tabID) { newValue in
                    withAnimation {
                        scrollProxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .background(.thickMaterial)

            Divider()
        }
    }

    /// Reorders within the visible workspace. The strip only ever shows one
    /// workspace's tabs, so a cross-workspace move cannot originate here.
    /// A drop whose tab is unknown to this store came from another window:
    /// it is received into the visible workspace instead of reordered.
    private func handleDrop(
        source: WorkspaceDragPayload,
        target: WorkspaceDragPayload,
        in workspace: WorkspaceSession
    ) {
        guard case let .tab(moving) = source,
              case let .tab(over) = target,
              let index = workspace.tabs.firstIndex(where: { $0.id == over })
        else { return }
        if store.liveSession(forTabID: moving) == nil {
            _ = onReceiveForeignTab?(moving)
            return
        }
        store.moveTab(moving, toWorkspace: workspace.id, at: index)
    }
}
/// The scrollable `HStack` of tab items. Split out from `VirtualTabBar.body`
/// because the combined `GeometryReader` → `ScrollView` → `HStack` → `ForEach`
/// closure nest was too much for the type checker to solve in one pass.
private struct VirtualTabBarStrip: View {
    let workspace: WorkspaceSession
    @ObservedObject var store: WorkspaceSessionStore
    let itemWidth: TabItemWidth
    let spacing: CGFloat
    @Binding var dropTarget: WorkspaceDragPayload?
    let onSelect: (UUID, UUID) -> Void
    let onClose: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void
    let onCloseToTheRight: (UUID) -> Void
    let onDrop: (WorkspaceDragPayload, WorkspaceDragPayload) -> Void

    /// Shared strip geometry for every tab's AppKit drag source: tear-off
    /// fires for releases outside this frame.
    private let dragContext = VirtualTabDragContext()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(workspace.tabs, id: \.id) { session in
                    itemView(for: session)
                }
            }
        }
        // Hit-test-transparent geometry anchor for tear-off detection; changes
        // nothing about how the strip handles clicks or drags.
        .background(VirtualTabDragStripAnchor(context: dragContext))
    }

    // Factored out of `body`'s `ForEach` closure: the compiler could not
    // type-check `VirtualTabBarItem`'s many-argument initializer inline
    // inside the `GeometryReader` → `ScrollView` → `HStack` → `ForEach` nest
    // in reasonable time. A function with an explicit `some View` return type
    // checks each layer independently.
    @ViewBuilder
    private func itemView(for session: TerminalSessionState) -> some View {
        VirtualTabBarItem(
            session: session,
            store: store,
            tabs: workspace.tabs,
            isSelected: session.id == store.snapshot.selection.tabID,
            dropTarget: $dropTarget,
            dragContext: dragContext,
            onSelect: { onSelect(workspace.id, session.id) },
            onClose: { onClose(session.id) },
            onCloseOthers: { onCloseOthers(session.id) },
            onCloseToTheRight: { onCloseToTheRight(session.id) },
            itemWidth: itemWidth,
            onDrop: onDrop
        )
        .id(session.id)
    }
}


/// A single tab in the strip.
private struct VirtualTabBarItem: View {
    /// Observed so a background tab's title/bell updates live. The session's
    /// metadata publishers are what drive this; a plain `let` would freeze the
    /// label at its initial value.
    @ObservedObject var session: TerminalSessionState
    @ObservedObject var store: WorkspaceSessionStore

    /// Every tab in this session's workspace, so the context menu can
    /// evaluate `TerminalController.canCloseOtherTabs`/`canCloseTabsOnTheRight`
    /// — the SAME predicates `validateMenuItem` uses — without depending on
    /// which physical controller happens to be presenting this workspace.
    let tabs: [TerminalSessionState]

    let isSelected: Bool
    @Binding var dropTarget: WorkspaceDragPayload?
    let dragContext: VirtualTabDragContext
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToTheRight: () -> Void

    /// Fixed width from `VirtualTabBar.tabItemWidth(availableWidth:tabCount:)`,
    /// computed by the parent from the real `GeometryReader`-reported strip
    /// width. Replaces the old `.frame(maxWidth: .infinity)` item-body frame
    /// so items don't stretch to fill an unbounded `ScrollView`.
    let itemWidth: TabItemWidth
    var onDrop: (WorkspaceDragPayload, WorkspaceDragPayload) -> Void

    @State private var hover = false
    @State private var isRenaming = false
    @State private var draftName = ""

    /// A renamed tab keeps its override; otherwise the terminal's own title.
    private var label: String {
        if let override = session.titleOverride, !override.isEmpty { return override }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Terminal" : title
    }

    private var tint: Color? {
        TerminalTabColor.fromStored(session.tabColor).swiftUIColor
    }

    private var isDropTarget: Bool {
        dropTarget == .tab(session.id)
    }

    var body: some View {
        HStack(spacing: 5) {
            // Reserved at all times so a tab that starts or stops ringing does
            // not resize itself and shove its neighbours sideways.
            Image(systemName: "bell.fill")
                .font(.system(size: 8.5))
                .foregroundStyle(.orange)
                .opacity(session.bell ? 1 : 0)

            if isRenaming {
                InlineRenameField(
                    text: $draftName,
                    onCommit: { name in
                        store.renameTab(session.id, to: name)
                        isRenaming = false
                    },
                    onCancel: { isRenaming = false })
            } else {
                // Constant weight. Switching to semibold on selection makes the
                // label wider, which reflows the strip on every click; selection
                // is already conveyed by the fill and the border.
                Text(label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Reserve the close button's width at all times so the label does
            // not reflow when the pointer enters or leaves the tab.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
            .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: itemWidth.points)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: isDropTarget ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draftName = label
            isRenaming = true
        }
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        // AppKit drag source: reports its lifecycle to the tear-off detector,
        // offers nothing outside the app (no Finder text clipping), and is
        // hit-test-transparent so every gesture below still reaches SwiftUI.
        .background(
            VirtualTabDragSource(
                context: dragContext,
                payload: .tab(session.id),
                previewText: label,
                dragDisabled: isRenaming))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let source = WorkspaceDragPayload(stringValue: raw),
                  source != .tab(session.id) else { return false }
            onDrop(source, .tab(session.id))
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTarget = .tab(session.id)
            } else if dropTarget == .tab(session.id) {
                dropTarget = nil
            }
        }
        .contextMenu {
            Button("Rename…") {
                draftName = label
                isRenaming = true
            }
            if session.titleOverride != nil {
                Button("Reset Name") { store.renameTab(session.id, to: "") }
            }
            Menu("Color") {
                TabColorMenuItems(current: .fromStored(session.tabColor)) { color in
                    store.setTabColor(session.id, to: color)
                }
            }
            Divider()
            Button("Close Tab") { onClose() }
            if TerminalController.canCloseOtherTabs(tabs: tabs) {
                Button("Close Other Tabs") { onCloseOthers() }
            }
            if TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: session.id) {
                Button("Close Tabs to the Right") { onCloseToTheRight() }
            }
        }
        .help(label)
    }

    /// A user-assigned color takes over the fill; otherwise selection uses the
    /// system accent and unselected tabs get a neutral wash.
    private var fillColor: Color {
        if let tint {
            return tint.opacity(isSelected ? 0.34 : (hover ? 0.20 : 0.14))
        }
        return isSelected
            ? Color.accentColor.opacity(0.28)
            : (hover ? Color.primary.opacity(0.09) : Color.primary.opacity(0.045))
    }

    private var borderColor: Color {
        if isDropTarget { return .accentColor }
        guard isSelected else { return .clear }
        return (tint ?? .accentColor).opacity(0.65)
    }
}
