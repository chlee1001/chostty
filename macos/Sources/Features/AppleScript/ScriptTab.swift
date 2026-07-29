import AppKit

/// AppleScript-facing wrapper around a single VIRTUAL tab.
///
/// `ScriptWindow.tabs` vends these objects so AppleScript can traverse
/// `window -> tab` without knowing anything about AppKit controllers.
///
/// Phase 5 flattening contract: a `tab` is exactly one entry of
/// `WorkspaceSessionStore.allSessions` — a workspace's virtual tab — never an
/// AppKit tab-group member (which no longer exists). `ScriptWindow.tabs`
/// enumerates every session across every workspace the window's controller
/// owns, in `allSessions` order, so scripting order and persistence order can
/// never diverge. Which workspace a tab belongs to is exposed read-only via
/// `workspace name` (sdef code `GTwN`); Phase 5 deliberately does NOT add a
/// `workspace` scripting class.
///
/// Tab identity belongs HERE, not to the physical controller. Before Phase 5,
/// `ScriptTab`'s stable id was derived from the owning controller's
/// `ObjectIdentifier`, so every tab in a window shared one id (there was only
/// ever one AppKit tab-group member to address). It is now keyed off the
/// virtual tab's own UUID (`TerminalSessionState.id`), which is stable for
/// that tab's lifetime and distinct per tab. This is a deliberate `id` string
/// change: a script that captured a `tab id "..."` reference before this
/// update will not resolve it afterwards.
@MainActor
@objc(GhosttyScriptTab)
final class ScriptTab: NSObject {
    /// Stable identifier used by AppleScript `tab id "..."` references.
    private let stableID: String

    /// The virtual tab UUID this wrapper addresses (`TerminalSessionState.id`).
    ///
    /// Distinct from `controller.presentedSessionID`: a `ScriptTab` may
    /// address a tab that is not currently mounted/presented, and `select`/
    /// `close` must scope to THIS tab, never whatever the controller happens
    /// to have presented.
    private let tabID: UUID

    /// Weak back-reference to the scripting window that owns this tab wrapper.
    ///
    /// We only need this for building an object specifier path — `index` and
    /// `selected` resolve through the retained `controller.workspaceStore`
    /// directly, not through this back-reference.
    private weak var window: ScriptWindow?

    /// The physical controller that owns this tab's workspace store. Needed
    /// for window-scoped operations (`select tab` brings the physical window
    /// forward; `close tab` falls back to closing the window when this is the
    /// last tab left) and to resolve which tree is authoritative for this
    /// tab's surfaces.
    private weak var controller: BaseTerminalController?

    /// Live session this tab wrapper addresses. Weak because the session can
    /// be torn down (tab closed) while a script still holds this wrapper.
    private weak var session: TerminalSessionState?

    /// Called by `ScriptWindow.tabs` / `ScriptWindow.selectedTab`.
    ///
    /// The ID is computed once so object specifiers built from this instance keep
    /// a consistent tab identity.
    init(window: ScriptWindow, controller: BaseTerminalController, session: TerminalSessionState) {
        self.stableID = Self.stableID(session: session)
        self.tabID = session.id
        self.window = window
        self.controller = controller
        self.session = session
    }

    /// Exposed as the AppleScript `id` property.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns THIS tab's own title, not the window's — a tab's title can
    /// differ from its window's when several tabs share one window.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        guard let session else { return "" }
        return session.titleOverride ?? session.title
    }

    /// Exposed as the AppleScript `workspace name` property (sdef code
    /// `GTwN`). Read-only membership label: a tab knows which workspace it
    /// belongs to, but AppleScript never addresses workspaces as their own
    /// object graph.
    @objc(workspaceName)
    var workspaceName: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        guard let controller else { return "" }
        return controller.workspaceStore.workspace(forTabID: tabID)?.name ?? ""
    }

    /// Exposed as the AppleScript `index` property.
    ///
    /// Cocoa scripting expects this to be 1-based for user-facing collections.
    /// Resolved from the retained `controller.workspaceStore` directly (as
    /// `workspaceName` already does), NOT the weak `window` back-reference —
    /// a torn-down `window` must not silently report the always-invalid
    /// index `0` for a tab whose controller is still alive.
    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        guard let controller else { return 0 }
        return controller.workspaceStore.allSessions
            .firstIndex(where: { $0.id == tabID })
            .map { $0 + 1 } ?? 0
    }

    /// Exposed as the AppleScript `selected` property.
    ///
    /// Powers script conditions such as `if selected of tab 1 then ...`.
    /// Compares against the store's `selection.tabID`. Resolved from the
    /// retained `controller.workspaceStore` directly, NOT the weak `window`
    /// back-reference, for the same reason as `index`.
    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let controller else { return false }
        return controller.workspaceStore.snapshot.selection.tabID == tabID
    }

    /// Exposed as the AppleScript `focused terminal` property.
    ///
    /// Resolves against THIS tab's own surfaces even when it is not the
    /// controller's presented tab, so `focused terminal of tab N` works for
    /// every tab, not only the mounted one.
    @objc(focusedTerminal)
    var focusedTerminal: ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let tree = effectiveSurfaceTree else { return nil }

        if let controller, tabID == controller.presentedSessionID,
           let focused = controller.focusedSurface,
           tree.contains(focused) {
            return ScriptTerminal(surfaceView: focused)
        }

        if let focusedID = session?.focusedSurfaceID ?? session?.rememberedSurfaceID,
           let surface = tree.first(where: { $0.id == focusedID }) {
            return ScriptTerminal(surfaceView: surface)
        }

        return tree.first.map(ScriptTerminal.init)
    }

    /// Best-effort native window containing this tab.
    var parentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.window
    }

    /// Live controller backing this tab wrapper.
    var parentController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller
    }

    /// Exposed as the AppleScript `terminals` element on a tab.
    ///
    /// Returns all terminal surfaces (split panes) within THIS tab.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        return (effectiveSurfaceTree ?? SplitTree<Ghostty.SurfaceView>()).map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a tab.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return effectiveSurfaceTree?
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// This tab's surface tree: the controller's live `surfaceTree` when this
    /// IS the presented tab, otherwise the session's own tree. Mirrors the
    /// split `BaseTerminalController.allWorkspaceSurfaces` makes — the
    /// presented session's authoritative tree lives on the controller; every
    /// other session's copy is only refreshed on write-back.
    private var effectiveSurfaceTree: SplitTree<Ghostty.SurfaceView>? {
        guard let controller, let session else { return nil }
        return tabID == controller.presentedSessionID ? controller.surfaceTree : session.surfaceTree
    }

    /// Handler for `select tab <tab>`.
    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let controller,
              let workspace = controller.workspaceStore.workspace(forTabID: tabID) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        // Present THIS addressed tab through the single mounting entry point
        // — not merely bring the window forward. Previously this only called
        // `makeKeyAndOrderFront`, so `select tab` on a non-presented tab
        // brought the window to the front without ever switching to it.
        controller.selectSession(workspaceID: workspace.id, tabID: tabID)
        controller.window?.makeKeyAndOrderFront(nil)
        return nil
    }

    /// Handler for `close tab <tab>`.
    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let controller else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        // Scope the close to THIS addressed tab, never the controller's
        // presented tab. The prior implementation always closed the
        // controller's PRESENTED tab (or the window) regardless of which tab
        // the script addressed with `close tab N`.
        if controller.workspaceStore.allSessions.count > 1 {
            controller.closeWorkspaceTab(tabID)
            return nil
        }

        // Last tab left in the window: fall back to closing the window itself.
        if let managedTerminalController = controller as? TerminalController {
            managedTerminalController.closeWindowImmediately()
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let window else { return nil }
        guard let windowClassDescription = window.classDescription as? NSScriptClassDescription else {
            return nil
        }
        guard let windowSpecifier = window.objectSpecifier else { return nil }

        // This tells Cocoa how to re-find this tab later:
        // application -> scriptWindows[id] -> tabs[id].
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}

extension ScriptTab {
    /// Stable ID for one virtual tab. Keyed off the tab's own UUID — tab
    /// identity belongs to the virtual tab (`TerminalSessionState`), not the
    /// physical controller that happens to be presenting it.
    static func stableID(session: TerminalSessionState) -> String {
        "tab-\(session.id.uuidString)"
    }

    /// Same scheme as `stableID(session:)`, for callers that only have the
    /// tab UUID (e.g. right after creating a tab, before wrapping it).
    static func stableID(tabID: UUID) -> String {
        "tab-\(tabID.uuidString)"
    }
}
