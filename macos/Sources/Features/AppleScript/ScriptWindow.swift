import AppKit

/// AppleScript-facing wrapper around a logical Ghostty window.
///
/// `ScriptWindow` presents one object per physical terminal window
/// controller. Its `tabs` collection is the Phase 5 flattened view: every
/// virtual tab across every workspace the controller owns, not just the
/// (at most one) AppKit tab-group member native tabbing used to expose. See
/// `ScriptTab`'s doc for the resulting identity/enumeration contract.
///
/// - It exposes stable IDs that Cocoa scripting can resolve later.
@MainActor
@objc(GhosttyScriptWindow)
final class ScriptWindow: NSObject {
    /// Stable identifier used by AppleScript `window id "..."` references.
    ///
    /// Derived from the controller's `physicalUUID`, not `NSWindow` object
    /// identity. `physicalUUID` is stable for the controller's whole
    /// lifetime, including before its `NSWindow` exists — but it is freshly
    /// minted on every launch (`physicalUUID = UUID()` in
    /// `BaseTerminalController.init`) and is never rehydrated from the `v8`
    /// restorable state's persisted `physicalID`, so a window's scripting
    /// `id` does NOT agree with its own value from a prior run after
    /// relaunch. Only same-run lifetime stability is guaranteed.
    let stableID: String

    /// The physical terminal window controller this scripting window wraps.
    private weak var primaryController: BaseTerminalController?

    /// `scriptWindows` in `AppDelegate+AppleScript` constructs these objects.
    ///
    /// `stableID` must match the same identity scheme used by
    /// `valueInScriptWindowsWithUniqueID:` so Cocoa can re-resolve object
    /// specifiers produced earlier in a script.
    init(primaryController: BaseTerminalController) {
        self.stableID = Self.stableID(primaryController: primaryController)
        self.primaryController = primaryController
    }

    /// Exposed as the AppleScript `id` property.
    ///
    /// This is what scripts read with `id of window ...`.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns the title of the window (from the selected/primary controller's NSWindow).
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return selectedController?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `tabs` element.
    ///
    /// Flattened across every virtual workspace this controller owns, in
    /// EXACTLY `WorkspaceSessionStore.allSessions` order — workspace, then
    /// tab within it — so scripting order and persistence order can never
    /// diverge. This is a deliberate behavior change from the pre-flattening
    /// wrapper (which returned one entry per AppKit tab-group member, at most
    /// one since native tabbing was already gone): a window with 2
    /// workspaces of 2 tabs each now reports 4 tabs instead of 1.
    @objc(tabs)
    var tabs: [ScriptTab] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        guard let primaryController else { return [] }
        return primaryController.workspaceStore.allSessions.map {
            ScriptTab(window: self, controller: primaryController, session: $0)
        }
    }

    /// Exposed as the AppleScript `selected tab` property.
    ///
    /// This powers expressions like `selected tab of window 1`. Compares
    /// against the store's desired `selection.tabID`, not merely what is
    /// currently mounted, so this stays correct mid-transaction.
    @objc(selectedTab)
    var selectedTab: ScriptTab? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let primaryController else { return nil }
        let selectedID = primaryController.workspaceStore.snapshot.selection.tabID
        guard let session = primaryController.workspaceStore.session(forTabID: selectedID) else { return nil }
        return ScriptTab(window: self, controller: primaryController, session: session)
    }

    /// Enables unique-ID lookup for `tabs` references.
    ///
    /// Required selector pattern for the `tabs` element key:
    /// `valueInTabsWithUniqueID:`.
    ///
    /// Cocoa uses this when a script resolves `tab id "..." of window ...`.
    @objc(valueInTabsWithUniqueID:)
    func valueInTabs(uniqueID: String) -> ScriptTab? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let primaryController else { return nil }
        guard let session = primaryController.workspaceStore.allSessions.first(where: {
            ScriptTab.stableID(session: $0) == uniqueID
        }) else { return nil }
        return ScriptTab(window: self, controller: primaryController, session: session)
    }

    /// Exposed as the AppleScript `terminals` element on a window.
    ///
    /// Backed by `allWorkspaceSurfaces` so every virtual tab's surfaces are
    /// reachable, not just the presented tab's `surfaceTree` — mirrors the
    /// `tab` flattening.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        guard let primaryController else { return [] }
        return primaryController.allWorkspaceSurfaces.map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a window.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let primaryController else { return nil }
        return primaryController.allWorkspaceSurfaces
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Best-effort native window to use as a tab parent for AppleScript commands.
    var preferredParentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return selectedController?.window ?? controllers.first?.window
    }

    /// Best-effort controller to use for window-scoped AppleScript commands.
    var preferredController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return selectedController ?? controllers.first
    }

    /// Live controller list for this scripting window.
    ///
    /// Native tabbing no longer exists, so a scripting window backs exactly
    /// one physical controller. This stays a list (rather than an Optional)
    /// so `terminals` can keep mapping over it uniformly.
    private var controllers: [BaseTerminalController] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        guard let primaryController else { return [] }
        return [primaryController]
    }

    /// Live selected controller for this scripting window.
    private var selectedController: BaseTerminalController? {
        primaryController
    }

    /// Handler for `activate window <window>`.
    @objc(handleActivateWindowCommand:)
    func handleActivateWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let windowContainer = preferredParentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return nil
    }

    /// Handler for `close window <window>`.
    @objc(handleCloseWindowCommand:)
    func handleCloseWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        if let managedTerminalController = preferredController as? TerminalController {
            managedTerminalController.closeWindowImmediately()
            return nil
        }

        guard let windowContainer = preferredParentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
            return nil
        }

        windowContainer.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    ///
    /// Without this, Cocoa can return data but cannot reliably build object
    /// references for later script statements. This specifier encodes:
    /// `application -> scriptWindows[id]`.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "scriptWindows",
            uniqueID: stableID
        )
    }
}

extension ScriptWindow {
    /// Produces the window-level stable ID from the primary controller's
    /// `physicalUUID`. Stable for the controller's whole in-process lifetime,
    /// including before its `NSWindow` exists — unlike the pre-Phase-5
    /// scheme, which keyed off `NSWindow`/controller `ObjectIdentifier`.
    ///
    /// Also stable ACROSS relaunch for a restored window: `physicalUUID` is
    /// persisted as `physicalID` and rehydrated by `restoreWindow`, so an id
    /// a script saved before quit still addresses the same window afterwards.
    /// A window that was not restored (restoration disabled, a decode
    /// failure, or a genuinely new window) mints a fresh one.
    static func stableID(primaryController: BaseTerminalController) -> String {
        "window-\(primaryController.physicalUUID.uuidString)"
    }
}
