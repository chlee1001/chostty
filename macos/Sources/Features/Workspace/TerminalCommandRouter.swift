import AppKit
import GhosttyKit

/// App-level router for reserved terminal commands (new workspace, new tab, new physical
/// window).
///
/// Per DR-7, this router is owned by `AppDelegate` and arbitrates reserved shortcuts
/// **before** any configured Ghostty core binding dispatch, `keyDown`, or menu-equivalent
/// fallback. Source may be `nil`; the resolution order provides a destination even when no
/// surface is focused.
///
/// Resolution order:
/// 1. Explicit ordinary source (the `source` parameter's owning controller).
/// 2. Key ordinary controller (key window's `TerminalController`).
/// 3. Main ordinary controller (main window's `TerminalController`).
/// 4. Weak last-main ordinary controller.
/// 5. Frontmost registered ordinary controller.
///
/// For commands that require an ordinary destination when none exists, exactly one new
/// physical 1×1 controller is created satisfying the requested result.
@MainActor
final class TerminalCommandRouter {
    /// The set of reserved product commands that this router arbitrates.
    enum ReservedTerminalCommand {
        /// Cmd+N — add a workspace to the resolved ordinary controller's store.
        case newWorkspace
        /// Cmd+T — add a virtual tab to the resolved ordinary workspace.
        case newTab
        /// Cmd+Shift+N — create one new independent physical window.
        case newPhysicalWindow
        /// Cmd+Shift+T — reopen the most recently closed tab (F8), per
        /// ``ClosedTabHistory`` on the resolved ordinary controller. Reassigned
        /// from `undo`; `undo` stays on `Cmd+Z`.
        case reopenClosedTab
    }

    /// Weak reference to the event dispatcher, which owns registry-backed
    /// source-surface → owning-controller resolution.
    weak var dispatcher: SurfaceEventDispatcher?
    /// Derives the surface configuration a new virtual tab/workspace should
    /// inherit from `source` (working directory, font size, etc. per the
    /// user's `window-inherit-*` settings).
    ///
    /// The legacy native-tab path got this for free by routing through
    /// libghostty's `new_tab` action. The virtual path constructs the
    /// `SurfaceView` directly, so it must ask libghostty for the same
    /// inherited configuration or every new tab silently opens in the shell's
    /// default directory instead of the current one.
    private static func inheritedConfig(
        from source: Ghostty.SurfaceView?,
        context: ghostty_surface_context_e
    ) -> Ghostty.SurfaceConfiguration? {
        guard let surface = source?.surface else { return nil }
        return Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(surface, context)
        )
    }

    /// Single implementation point for resolving the working directory (and
    /// other config) a brand-new surface should spawn with, per F5's
    /// precedence rules. Called from both `createVirtualTab` and
    /// `BaseTerminalController.newVirtualWorkspace`.
    ///
    /// Precedence, highest first:
    /// 1. An **explicitly requested** `workingDirectory` — never overridden.
    /// 2. The workspace's `defaultDirectory`, when non-nil AND still an
    ///    existing directory. A stale/deleted path falls through to the next
    ///    rung rather than failing the spawn.
    /// 3. The inherited working directory (the workspace default deliberately
    ///    outranks this, because it is an explicit user statement).
    /// 4. Shell default.
    ///
    /// `origin` is what makes rung 1 honest. libghostty hands us a config whose
    /// `workingDirectory` is populated purely because
    /// `window-inherit-working-directory` is on; that is rung-3 material, not a
    /// caller's explicit request. Passing it as `.explicit` would short-circuit
    /// at rung 1 and silently beat the workspace default.
    static func resolvedConfig(
        workspace: WorkspaceSession?,
        source: Ghostty.SurfaceView?,
        context: ghostty_surface_context_e,
        baseConfig: Ghostty.SurfaceConfiguration?,
        origin: ConfigOrigin = .explicit
    ) -> Ghostty.SurfaceConfiguration? {
        // Rung 1: only a genuinely explicit request wins outright.
        if origin == .explicit, let baseConfig, baseConfig.workingDirectory != nil {
            return baseConfig
        }

        // Everything below overlays onto baseConfig rather than replacing it,
        // so a caller that supplied only a command or environment keeps those
        // fields while still getting a resolved directory.
        var config = baseConfig ?? Ghostty.SurfaceConfiguration()

        // Rung 2: the workspace's own default, when set and still a directory.
        if let dir = workspace?.defaultDirectory, directoryExists(dir) {
            config.workingDirectory = dir
            return config
        }

        // Rung 3: the inherited directory — either the one libghostty already
        // computed and handed us, or one derived from the source surface.
        if origin == .inherited, let inherited = baseConfig?.workingDirectory {
            config.workingDirectory = inherited
            return config
        }
        if let inheritedConfig = inheritedConfig(from: source, context: context),
           let dir = inheritedConfig.workingDirectory {
            config.workingDirectory = dir
            return config
        }

        // Rung 4: shell default. Preserve a caller's other fields; return nil
        // only when there was nothing to carry.
        return baseConfig
    }

    /// Whether a supplied `workingDirectory` was explicitly requested by the
    /// caller or merely inherited from the source surface.
    enum ConfigOrigin {
        case explicit
        case inherited
    }

    /// Whether `path` names a directory that currently exists on disk. Used
    /// to detect a stale/deleted `defaultDirectory` so it can fall through
    /// rather than failing tab/workspace creation.
    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Creates one virtual tab in the resolved ordinary controller and mounts
    /// it, returning that controller.
    ///
    /// This is the single entry point every "new tab" surface must use —
    /// keyboard, menu, Services, AppleScript, App Intents, dock drop — so none
    /// of them can fall back to creating a physical window for a command the
    /// product defines as virtual.
    ///
    /// When no ordinary controller exists there is nothing to add a tab to, so
    /// exactly one physical 1×1 controller is created to satisfy the request.
    @discardableResult
    func createVirtualTab(
        source: Ghostty.SurfaceView? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        origin: ConfigOrigin = .explicit
    ) -> TerminalController? {
        guard let app = resolvedGhosttyApp() else { return nil }

        guard let controller = resolvedController(from: source),
              let ghostty_app = controller.ghostty.app else {
            // No ordinary destination: create one 1×1 physical hierarchy.
            return TerminalController.newWindow(app, withBaseConfig: baseConfig)
        }

        let ownerWorkspace = source.flatMap { controller.workspaceStore.workspace(forSurfaceID: $0.id) }
            ?? controller.workspaceStore.selectedWorkspace
        let config = Self.resolvedConfig(
            workspace: ownerWorkspace,
            source: source ?? controller.focusedSurface,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            baseConfig: baseConfig,
            origin: origin)
        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        let newTree = SplitTree<Ghostty.SurfaceView>(view: newSurface)
        let session = TerminalSessionState(id: UUID(), surfaceTree: newTree)
        controller.workspaceStore.addTab(session, toWorkspace: ownerWorkspace?.id)
        let sel = controller.workspaceStore.snapshot.selection
        controller.selectSession(workspaceID: sel.workspaceID, tabID: sel.tabID)
        return controller
    }
    /// Performs a reserved terminal command, resolving the destination controller from the
    /// optional `source` and the standard resolution order.
    ///
    /// - Returns: `true` if the command was handled; `false` if no destination could be
    ///   found/created or the command was not handled.
    func perform(
        _ command: ReservedTerminalCommand,
        source: Ghostty.SurfaceView?
    ) -> Bool {
        switch command {
        case .newPhysicalWindow:
            // A physical window is always created regardless of source.
            guard let app = resolvedGhosttyApp() else { return false }
            _ = TerminalController.newWindow(app)
            return true

        case .newTab:
            // Cmd+T: add a virtual tab to the resolved workspace.
            return createVirtualTab(source: source) != nil

        case .newWorkspace:
            // Cmd+N: create a virtual workspace in the resolved controller's store.
            // If no ordinary destination exists, create a new physical 1×1 controller.
            guard resolvedGhosttyApp() != nil else { return false }
            if let controller = resolvedController(from: source) {
                _ = controller.newVirtualWorkspace(source: source ?? controller.focusedSurface)
                return true
            }
            // No ordinary destination — create one to satisfy the result.
            guard let app = resolvedGhosttyApp() else { return false }
            _ = TerminalController.newWindow(app)
            return true

        case .reopenClosedTab:
            // Cmd+Shift+T: reopen the resolved controller's most recently
            // closed tab. Unlike the other reserved commands, there is
            // nothing to reopen without an existing ordinary destination, so
            // this never creates a new physical window.
            guard let controller = resolvedController(from: source) else { return false }
            controller.reopenClosedTab()
            return true
        }
    }

    /// Hardware key codes for the reserved product shortcuts. These are
    /// layout-independent: the physical key reports the same code under a
    /// Korean 2-Set layout as it does under US QWERTY, whereas
    /// `charactersIgnoringModifiers` would report "ㅜ" / "ㅅ" and miss.
    private enum ReservedKeyCode {
        static let n: UInt16 = 45
        static let t: UInt16 = 17
    }
    /// Every chord this router claims, for the config-reload collision walk
    /// (`AppDelegate.reservedChordCollisions`) that detects a user keybind on
    /// the exact same chord — which would otherwise be silently swallowed
    /// since this router intercepts BEFORE `ghostty_config_key_is_binding`
    /// ever runs.
    static let reservedChords: [ReservedChordDescriptor] = [
        .init(label: "Cmd+N", keyCode: ReservedKeyCode.n, modifierFlags: .command),
        .init(label: "Cmd+T", keyCode: ReservedKeyCode.t, modifierFlags: .command),
        .init(label: "Cmd+Shift+N", keyCode: ReservedKeyCode.n, modifierFlags: [.command, .shift]),
        .init(label: "Cmd+Shift+T", keyCode: ReservedKeyCode.t, modifierFlags: [.command, .shift]),
    ]

    /// The outcome of matching an event against the reserved shortcut table.
    enum Recognition: Equatable {
        /// Not a reserved shortcut; the event must continue down the responder
        /// chain to Ghostty core bindings and menu equivalents.
        case unmatched
        /// A reserved shortcut whose repeat must be swallowed without acting,
        /// so a held chord creates exactly one workspace/tab/window.
        case consumedRepeat
        /// A reserved shortcut that should execute `command`.
        case command(ReservedTerminalCommand)
    }

    /// Pure, side-effect-free recognition. Separated from execution so the
    /// layout/repeat/modifier contract is directly testable without a live
    /// controller, window, or ghostty app.
    func recognize(_ event: NSEvent) -> Recognition {
        guard event.type == .keyDown else { return .unmatched }

        // Narrowed to exactly the modifiers these chords care about — NOT
        // `.deviceIndependentFlagsMask`, which also includes `.capsLock`,
        // `.numericPad`, `.function` and `.help`. Caps Lock being active must
        // not break these chords, but the mask must still compare for EXACT
        // equality below so `Cmd+Alt+1` and `Cmd+[` stay unclaimed.
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let keyCode = event.keyCode

        let matched: ReservedTerminalCommand?
        if mods == [.command, .shift] {
            switch keyCode {
            case ReservedKeyCode.n: matched = .newPhysicalWindow
            case ReservedKeyCode.t: matched = .reopenClosedTab
            default: matched = nil
            }
        } else if mods == .command {
            switch keyCode {
            case ReservedKeyCode.n: matched = .newWorkspace
            case ReservedKeyCode.t: matched = .newTab
            default: matched = nil
            }
        } else {
            matched = nil
        }

        guard let matched else { return .unmatched }

        // A repeat is still *ours* — we swallow it so it cannot fall through to
        // a core binding, but we do not execute it again.
        if event.isARepeat { return .consumedRepeat }
        return .command(matched)
    }

    /// Checks whether `event` matches a reserved shortcut (Cmd+N, Cmd+T, Cmd+Shift+N) and,
    /// if so, performs the corresponding command.
    ///
    /// - Returns: `true` when the event was consumed by this router and must not
    ///   propagate further. A recognized shortcut is consumed even when
    ///   execution fails, so a failed workspace creation can never silently fall
    ///   back to the legacy native-window path.
    func performReservedShortcut(
        _ event: NSEvent,
        source: Ghostty.SurfaceView?
    ) -> Bool {
        switch recognize(event) {
        case .unmatched:
            return false
        case .consumedRepeat:
            return true
        case .command(let command):
            _ = perform(command, source: source)
            return true
        }
    }

    // MARK: - Resolution

    /// Resolves the destination `TerminalController` following the DR-7 order:
    /// explicit source (dispatcher → registry → window) → key → main → last-main → frontmost.
    private func resolvedController(
        from source: Ghostty.SurfaceView?
    ) -> TerminalController? {
        // 1. Explicit source via dispatcher (preferred — handles inactive/non-presented).
        if let source, let dispatcher {
            if let controller = dispatcher.controller(for: source) {
                return controller
            }
        }

        // 2. Fallback to preferredParent (key → main → lastMain → all.last).
        return TerminalController.preferredParent
    }

    /// Resolves the process-wide `Ghostty.App` from the AppDelegate.
    private func resolvedGhosttyApp() -> Ghostty.App? {
        (NSApplication.shared.delegate as? AppDelegate)?.ghostty
    }
}
