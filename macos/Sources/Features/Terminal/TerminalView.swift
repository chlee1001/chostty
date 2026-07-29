import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    var updateOverlayIsVisible: Bool { get }

    /// The per-controller workspace store for virtual workspaces (DR-1/Phase 1).
    /// Nonoptional: every controller receives a fully-initialized store via the
    /// graph factory before presentation.
    var workspaceStore: WorkspaceSessionStore { get }

    /// Select a workspace/tab. The controller drives the store's stage→commit
    /// transaction and mounts the resulting session at the new generation.
    func selectSession(workspaceID: UUID, tabID: UUID)

    /// Close a virtual tab by UUID. The controller handles session teardown.
    func closeWorkspaceTab(_ tabID: UUID)

    /// Close every OTHER virtual tab in `tabID`'s workspace (context-menu
    /// "Close Other Tabs", anchored at whichever tab was clicked). On
    /// `BaseTerminalController` (not `TerminalController`-only) so this can
    /// be a protocol requirement instead of an `as? TerminalController` cast
    /// that would silently no-op for any other conformer.
    func closeOtherTabs(fromTab tabID: UUID)

    /// Close every virtual tab to the right of `tabID` in its workspace
    /// (context-menu "Close Tabs to the Right"). See `closeOtherTabs(fromTab:)`.
    func closeTabsOnTheRight(fromTab tabID: UUID)

    /// Close a virtual workspace by UUID.
    func closeWorkspace(_ workspaceID: UUID)
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize
    @AppStorage("chostty.sidebarVisible") private var sidebarVisible: Bool = true
    @AppStorage("chostty.sidebarWidth") private var sidebarWidth: Double = 220

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        SidebarView(
                            workspaceSessionStore: viewModel.workspaceStore,
                            onToggle: { sidebarVisible.toggle() },
                            onNewWorkspace: {
                                guard let appDelegate = NSApp.delegate as? AppDelegate,
                                      let router = appDelegate.terminalCommands as TerminalCommandRouter?,
                                      let surface = viewModel.surfaceTree.first else { return }
                                _ = router.perform(.newWorkspace, source: surface)
                            },
                            onSelectTab: { workspaceID, tabID in
                                viewModel.selectSession(workspaceID: workspaceID, tabID: tabID)
                            },
                            onCloseTab: { tabID in
                                viewModel.closeWorkspaceTab(tabID)
                            },
                            onCloseWorkspace: { wsID in
                                viewModel.closeWorkspace(wsID)
                            },
                            onReopenClosedTab: {
                                guard let appDelegate = NSApp.delegate as? AppDelegate,
                                      let router = appDelegate.terminalCommands as TerminalCommandRouter?,
                                      let surface = viewModel.surfaceTree.first else { return }
                                _ = router.perform(.reopenClosedTab, source: surface)
                            }
                        )
                        .frame(width: sidebarWidth)

                        SidebarDivider(width: $sidebarWidth)
                    }

                    VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    // Virtual tab strip. Renders only when the selected
                    // workspace has more than one tab.
                    VirtualTabBar(
                        store: viewModel.workspaceStore,
                        onSelect: { wsID, tabID in
                            viewModel.selectSession(workspaceID: wsID, tabID: tabID)
                        },
                        onClose: { tabID in
                            viewModel.closeWorkspaceTab(tabID)
                        },
                        onCloseOthers: { tabID in
                            viewModel.closeOtherTabs(fromTab: tabID)
                        },
                        onCloseToTheRight: { tabID in
                            viewModel.closeTabsOnTheRight(fromTab: tabID)
                        }
                    )

                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        action: { delegate?.performSplitAction($0) })
                        .environmentObject(ghostty)
                        .ghosttyLastFocusedSurface(lastFocusedSurface)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                                self.delegate?.focusedSurfaceDidChange(to: newValue)
                            }
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])
                }

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
                // Cmd+B toggles the sidebar
                Button("") { sidebarVisible.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Chostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Chostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Chostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
