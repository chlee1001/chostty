import AppKit
import SwiftUI
import GhosttyKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// Posted when a terminal window awakes from nib.
    static let terminalDidAwake = Notification.Name("TerminalWindowDidAwake")

    /// Posted when a terminal window will close
    static let terminalWillCloseNotification = Notification.Name("TerminalWindowWillClose")

    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// Reset split zoom button in titlebar
    private let resetZoomAccessory = NSTitlebarAccessoryViewController()

    /// Update notification UI in titlebar
    private let updateAccessory = NSTitlebarAccessoryViewController()

    /// Workspace controls (sidebar toggle, new workspace, workspace actions)
    /// hosted immediately right of the traffic lights.
    private let workspaceControlsAccessory = NSTitlebarAccessoryViewController()

    /// Whether `installWorkspaceControls` has run. `addTitlebarAccessoryViewController`
    /// would happily add the same controller twice.
    private var workspaceControlsInstalled = false

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// Whether this window supports the update accessory. If this is false, then views within this
    /// window should determine how to show update notifications.
    var supportsUpdateAccessory: Bool {
        // Native window supports it.
        true
    }

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    /// The color assigned to this window's tab. Marks the window's restorable
    /// state as dirty; the tab color is not rendered anywhere in-window
    /// (`TabColorIndicatorView` render lived only in the deleted NSWindowTab
    /// accessory) — it is read back for persistence (Command Palette,
    /// window restoration) and to seed newly-duplicated/reopened tabs.
    var tabColor: TerminalTabColor = .none {
        didSet {
            guard tabColor != oldValue else { return }
            invalidateRestorableState()
        }
    }

    // MARK: NSWindow Overrides

    override var toolbar: NSToolbar? {
        didSet {
            DispatchQueue.main.async {
                // When we have a toolbar, our SwiftUI view needs to know for layout
                self.viewModel.hasToolbar = self.toolbar != nil
            }
        }
    }

    override func awakeFromNib() {
        // Notify that this terminal window has loaded
        NotificationCenter.default.post(name: Self.terminalDidAwake, object: self)

        // Chostty uses virtual workspaces instead of native macOS tabs.
        // Disabling tabbing prevents AppKit tab-group creation so Cmd+T
        // and window ordering don't interfere with virtual workspace switching.
        tabbingMode = .disallowed

        // All new windows are based on the app config at the time of creation.
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let config = appDelegate.ghostty.config

        // Setup our initial config
        derivedConfig = .init(config)

        // If there is a hardcoded title in the configuration, we set that
        // immediately. Future `set_title` apprt actions will override this
        // if necessary but this ensures our window loads with the proper
        // title immediately rather than on another event loop tick (see #5934)
        if let title = derivedConfig.title {
            self.title = title
        }

        // If window decorations are disabled, remove our title
        if !config.windowDecorations { styleMask.remove(.titled) }

        // NOTE: setInitialWindowPosition is NOT called here because subclass
        // awakeFromNib may still change frame-affecting state (e.g.
        // HiddenTitlebarTerminalWindow's styleMask change in
        // `reapplyHiddenStyle`). It is called from TerminalController.windowDidLoad
        // after the window is fully set up.

        // If our traffic buttons should be hidden, then hide them
        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        // Create our reset zoom titlebar accessory. We have to have a title
        // to do this or AppKit triggers an assertion.
        if styleMask.contains(.titled) {
            resetZoomAccessory.layoutAttribute = .right
            resetZoomAccessory.view = NSHostingView(rootView: ResetZoomAccessoryView(
                viewModel: viewModel,
                action: { [weak self] in
                    guard let self else { return }
                    self.terminalController?.splitZoom(self)
                }))
            addTitlebarAccessoryViewController(resetZoomAccessory)
            resetZoomAccessory.view.translatesAutoresizingMaskIntoConstraints = false

            // Create update notification accessory
            if supportsUpdateAccessory {
                updateAccessory.layoutAttribute = .right
                updateAccessory.view = NonDraggableHostingView(rootView: UpdateAccessoryView(
                    viewModel: viewModel,
                    model: appDelegate.updateViewModel
                ))
                addTitlebarAccessoryViewController(updateAccessory)
                updateAccessory.view.translatesAutoresizingMaskIntoConstraints = false
            }
        }

        // Get our saved level
        level = UserDefaults.ghostty.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func close() {
        NotificationCenter.default.post(name: Self.terminalWillCloseNotification, object: self)
        super.close()
    }

    override func becomeMain() {
        super.becomeMain()
        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()
        viewModel.isMainWindow = false
    }

    // MARK: Workspace Controls

    /// Installs `content` as the leading titlebar accessory, which AppKit lays
    /// out immediately right of the traffic lights.
    ///
    /// Called by the controller rather than from `awakeFromNib` because the view
    /// needs the controller's workspace store, and `windowController` is still
    /// nil while the nib is loading.
    func installWorkspaceControls<Content: View>(_ content: Content) {
        guard styleMask.contains(.titled), !workspaceControlsInstalled else { return }
        workspaceControlsInstalled = true

        workspaceControlsAccessory.layoutAttribute = .leading

        // NonDraggableHostingView: a plain NSHostingView in the titlebar lets a
        // click-drag move the window instead of pressing the button under it.
        let host = NonDraggableHostingView(rootView: content)

        // Frame-based sizing on purpose. A constraints-based accessory view
        // (`translatesAutoresizingMaskIntoConstraints = false`) resolves to zero
        // width inside `NSTitlebarAccessoryClipView`, which clips the buttons away
        // while still laying them out — they stay reachable by accessibility and
        // are invisible on screen.
        host.frame = NSRect(origin: .zero, size: host.fittingSize)

        workspaceControlsAccessory.view = host
        addTitlebarAccessoryViewController(workspaceControlsAccessory)
    }

    /// Hidden whenever the controls render as an in-window strip instead, so the
    /// titlebar that slides down over native fullscreen doesn't show a second
    /// copy of the same buttons.
    var workspaceControlsAccessoryHidden: Bool {
        get { workspaceControlsAccessory.isHidden }
        set {
            guard workspaceControlsInstalled else { return }
            workspaceControlsAccessory.isHidden = newValue
        }
    }

    // MARK: Surface Zoom

    /// Set to true if a surface is currently zoomed to show the reset zoom button.
    var surfaceIsZoomed: Bool = false {
        didSet {
            DispatchQueue.main.async {
                self.viewModel.isSurfaceZoomed = self.surfaceIsZoomed
            }
        }
    }

    // MARK: Title Text

    override var title: String {
        didSet {
            /// We always keep single-line mode on; with native tabbing gone
            /// there is no tab-bar-driven copy of this setting to guard against.
            titlebarTextField?.usesSingleLineMode = true
        }
    }

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

            titlebarTextField?.font = font
            /// Always single-line: with native tabbing gone there is no
            /// tab-bar-driven copy of this setting that could vertically
            /// misalign the title.
            titlebarTextField?.usesSingleLineMode = true
        }
    }

    // Find the NSTextField responsible for displaying the titlebar's title.
    private var titlebarTextField: NSTextField? {
        titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")?
            .firstDescendant(withClassName: "NSTextField") as? NSTextField
    }

    // Return a styled representation of our title property.
    var attributedTitle: NSAttributedString? {
        guard let titlebarFont = titlebarFont else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
    }

    var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            return contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            return window.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    // MARK: Positioning And Styling

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard isVisible else { return }
        defer { updateColorSchemeForSurfaceTree() }

        // Basic properties
        appearance = surfaceConfig.windowAppearance
        hasShadow = surfaceConfig.macosWindowShadow

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        //
        // Also check if the user has overridden transparency to be fully opaque.
        let forceOpaque = terminalController?.isBackgroundOpaque ?? false
        if !styleMask.contains(.fullScreen) &&
            !forceOpaque &&
            (surfaceConfig.backgroundOpacity < 1 || surfaceConfig.backgroundBlur.isGlassStyle) {
            isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            backgroundColor = .white.withAlphaComponent(0.001)

            // We don't need to set blur when using glass
            if !surfaceConfig.backgroundBlur.isGlassStyle, let appDelegate = NSApp.delegate as? AppDelegate {
                ghostty_set_window_background_blur(
                    appDelegate.ghostty.app,
                    Unmanaged.passUnretained(self).toOpaque())
            }
        } else {
            isOpaque = true

            let backgroundColor = preferredBackgroundColor ?? NSColor(surfaceConfig.backgroundColor)
            self.backgroundColor = backgroundColor.withAlphaComponent(1)
        }
    }

    /// The preferred window background color. The current window background color may not be set
    /// to this, since this is dynamic based on the state of the surface tree.
    ///
    /// This background color will include alpha transparency if set. If the caller doesn't want that,
    /// change the alpha channel again manually.
    var preferredBackgroundColor: NSColor? {
        if let terminalController, !terminalController.surfaceTree.isEmpty {
            let surface: Ghostty.SurfaceView?

            // If our focused surface borders the top then we prefer its background color
            if let focusedSurface = terminalController.focusedSurface,
               let treeRoot = terminalController.surfaceTree.root,
               let focusedNode = treeRoot.node(view: focusedSurface),
               treeRoot.spatial().doesBorder(side: .up, from: focusedNode) {
                surface = focusedSurface
            } else {
                // If it doesn't border the top, we use the top-left leaf
                surface = terminalController.surfaceTree.root?.leftmostLeaf()
            }

            if let surface {
                let backgroundColor = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
                let alpha = surface.derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
                return NSColor(backgroundColor).withAlphaComponent(alpha)
            }
        }

        let alpha = derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
        return derivedConfig.backgroundColor.withAlphaComponent(alpha)
    }

    func updateColorSchemeForSurfaceTree() {
        terminalController?.updateColorSchemeForSurfaceTree()
    }

    func setInitialWindowPosition(x: Int16?, y: Int16?) -> Bool {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x = x, let y = y else {
            return false
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = screen ?? NSScreen.screens.first else {
            return false
        }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        setFrameOrigin(safeOrigin)
        return true
    }

    private func hideWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: Config

    struct DerivedConfig {
        let title: String?
        let backgroundBlur: Ghostty.Config.BackgroundBlur
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let windowCornerRadius: CGFloat

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
            self.backgroundBlur = .disabled
            self.macosTitlebarStyle = .default
            self.windowCornerRadius = 16
        }

        init(_ config: Ghostty.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
            self.backgroundBlur = config.backgroundBlur
            self.macosTitlebarStyle = config.macosTitlebarStyle

            // `tabs` is silently aliased to `transparent` at the config read
            // site, so every reachable style uses the 16pt radius.
            self.windowCornerRadius = 16
        }
    }
}

// MARK: SwiftUI View

extension TerminalWindow {
    class ViewModel: ObservableObject {
        @Published var isSurfaceZoomed: Bool = false
        @Published var hasToolbar: Bool = false
        @Published var isMainWindow: Bool = true

        /// Calculates the top padding based on toolbar visibility and macOS version
        fileprivate var accessoryTopPadding: CGFloat {
            if #available(macOS 26.0, *) {
                return hasToolbar ? 10 : 5
            } else {
                return hasToolbar ? 9 : 4
            }
        }
    }

    struct ResetZoomAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        let action: () -> Void

        var body: some View {
            if viewModel.isSurfaceZoomed {
                VStack {
                    Button(action: action) {
                        Image("ResetZoom")
                            .foregroundColor(viewModel.isMainWindow ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset Split Zoom")
                    .frame(width: 20, height: 20)
                    Spacer()
                }
                // With a toolbar, the window title is taller, so we need more padding
                // to properly align.
                .padding(.top, viewModel.accessoryTopPadding)
                // We always need space at the end of the titlebar
                .padding(.trailing, 10)
            }
        }
    }

    /// A pill-shaped button that displays update status and provides access to update actions.
    struct UpdateAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        @ObservedObject var model: UpdateViewModel

        var body: some View {
            // We use the same top/trailing padding so that it hugs the same.
            UpdatePill(model: model)
                .padding(.top, viewModel.accessoryTopPadding)
                .padding(.trailing, viewModel.accessoryTopPadding)
        }
    }

}

