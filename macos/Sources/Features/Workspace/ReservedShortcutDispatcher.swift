import AppKit

/// Describes one reserved (non-configurable) product keyboard chord, for the
/// config-reload collision walk in `AppDelegate.reservedChordCollisions`.
struct ReservedChordDescriptor {
    let label: String
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
}

/// Recognizes and performs the reserved workspace/tab-switch shortcuts
/// (F1): `Cmd+1`…`Cmd+8` (select workspace by index), `Cmd+9` (select the
/// last workspace), `Cmd+Shift+[` / `Cmd+Shift+]` (previous/next virtual tab
/// within the selected workspace), and `Ctrl+Tab` / `Ctrl+Shift+Tab`
/// (next/previous workspace).
///
/// Split into a pure `decision(for:keyWindowKind:firstResponderIsTextField:)`
/// — directly unit-testable without a live window, controller, or ghostty
/// app — and a `perform(_:on:)` that applies the recognized action to a
/// resolved controller's `workspaceStore`.
///
/// These shortcuts deliberately do **not** claim `Cmd+Alt+arrows` or
/// `Cmd+[` / `Cmd+]`, which are LIVE `goto_split` Darwin defaults
/// (`Config.zig`); stealing them would destroy split navigation. `Cmd+0` is
/// also live (`reset_font_size`) and is likewise left unclaimed.
@MainActor
enum ReservedShortcutDispatcher {
    /// Hardware key codes for the reserved shortcuts. Layout-independent:
    /// the physical key reports the same code under a Korean 2-Set layout as
    /// it does under US QWERTY, whereas `charactersIgnoringModifiers` would
    /// report "ㅜ" / "ㅅ" and miss.
    ///
    /// NON-MONOTONIC — do not assume `18 + n`.
    private enum ReservedKeyCode {
        static let one: UInt16 = 18
        static let two: UInt16 = 19
        static let three: UInt16 = 20
        static let four: UInt16 = 21
        static let five: UInt16 = 23
        static let six: UInt16 = 22
        static let seven: UInt16 = 26
        static let eight: UInt16 = 28
        static let nine: UInt16 = 25
        // `zero = 29` is intentionally never matched below. Cmd+0 is LIVE:
        // Config.zig binds it to `reset_font_size`. It is listed here only
        // so a future edit does not reach for it as a "free" chord.
        static let leftBracket: UInt16 = 33
        static let rightBracket: UInt16 = 30
        static let tab: UInt16 = 48
    }

    /// Every chord this dispatcher claims, for the config-reload collision
    /// walk (`AppDelegate.reservedChordCollisions`) that detects a user
    /// keybind on the exact same chord — which would otherwise be silently
    /// swallowed since this dispatcher intercepts BEFORE
    /// `ghostty_config_key_is_binding` ever runs.
    static let reservedChords: [ReservedChordDescriptor] = [
        .init(label: "Cmd+1", keyCode: ReservedKeyCode.one, modifierFlags: .command),
        .init(label: "Cmd+2", keyCode: ReservedKeyCode.two, modifierFlags: .command),
        .init(label: "Cmd+3", keyCode: ReservedKeyCode.three, modifierFlags: .command),
        .init(label: "Cmd+4", keyCode: ReservedKeyCode.four, modifierFlags: .command),
        .init(label: "Cmd+5", keyCode: ReservedKeyCode.five, modifierFlags: .command),
        .init(label: "Cmd+6", keyCode: ReservedKeyCode.six, modifierFlags: .command),
        .init(label: "Cmd+7", keyCode: ReservedKeyCode.seven, modifierFlags: .command),
        .init(label: "Cmd+8", keyCode: ReservedKeyCode.eight, modifierFlags: .command),
        .init(label: "Cmd+9", keyCode: ReservedKeyCode.nine, modifierFlags: .command),
        .init(label: "Cmd+Shift+[", keyCode: ReservedKeyCode.leftBracket, modifierFlags: [.command, .shift]),
        .init(label: "Cmd+Shift+]", keyCode: ReservedKeyCode.rightBracket, modifierFlags: [.command, .shift]),
        .init(label: "Ctrl+Tab", keyCode: ReservedKeyCode.tab, modifierFlags: .control),
        .init(label: "Ctrl+Shift+Tab", keyCode: ReservedKeyCode.tab, modifierFlags: [.control, .shift]),
    ]

    /// The kind of window currently key, as far as this dispatcher cares.
    /// Anything that is not an ordinary `TerminalWindow` (Settings, the quick
    /// terminal, or no key window at all) must never have a reserved
    /// shortcut applied to it.
    enum KeyWindowKind: Equatable {
        case terminal
        case other
    }

    /// A reserved shortcut action, pending execution against a resolved
    /// controller.
    enum Action: Equatable {
        /// Select the LAST workspace, whatever its index. Cmd+9 replaces
        /// core's `last_tab` and must reach the true last one.
        case selectLastWorkspace

        /// Select a workspace by 1-based index. Out-of-range indices clamp
        /// to the last workspace.
        case selectWorkspace(index: Int)
        /// Select the previous/next virtual tab within the selected
        /// workspace.
        case previousTab
        case nextTab
        /// Select the previous/next workspace.
        case previousWorkspace
        case nextWorkspace
    }

    /// The outcome of matching an event against the reserved shortcut table.
    enum Decision: Equatable {
        /// Not a reserved shortcut; the event must continue down the
        /// responder chain to Ghostty core bindings and menu equivalents.
        case unmatched
        /// A reserved shortcut whose repeat must be swallowed without
        /// acting, so a held chord performs exactly one switch.
        case consumedRepeat
        /// A reserved shortcut that should execute `action`.
        case action(Action)
    }

    /// Pure, side-effect-free recognition. Separated from execution so the
    /// layout/repeat/modifier/guard contract is directly testable without a
    /// live controller, window, or ghostty app.
    ///
    /// Applies only when `keyWindowKind == .terminal` and
    /// `firstResponderIsTextField == false` — this protects the sidebar's
    /// inline workspace/tab rename field (and the F6 filter field) from
    /// having its keystrokes stolen.
    static func decision(
        for event: NSEvent,
        keyWindowKind: KeyWindowKind,
        firstResponderIsTextField: Bool
    ) -> Decision {
        guard event.type == .keyDown else { return .unmatched }
        guard keyWindowKind == .terminal else { return .unmatched }
        guard !firstResponderIsTextField else { return .unmatched }

        // Narrowed to exactly the modifiers these chords care about — NOT
        // `.deviceIndependentFlagsMask`, which also includes `.capsLock`,
        // `.numericPad`, `.function` and `.help`. Caps Lock being active must
        // not break `Cmd+1`, but the mask must still compare for EXACT
        // equality below so `Cmd+Alt+1` and `Cmd+[` stay unclaimed.
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let keyCode = event.keyCode

        let matched: Action?
        if mods == .command {
            switch keyCode {
            case ReservedKeyCode.one: matched = .selectWorkspace(index: 1)
            case ReservedKeyCode.two: matched = .selectWorkspace(index: 2)
            case ReservedKeyCode.three: matched = .selectWorkspace(index: 3)
            case ReservedKeyCode.four: matched = .selectWorkspace(index: 4)
            case ReservedKeyCode.five: matched = .selectWorkspace(index: 5)
            case ReservedKeyCode.six: matched = .selectWorkspace(index: 6)
            case ReservedKeyCode.seven: matched = .selectWorkspace(index: 7)
            case ReservedKeyCode.eight: matched = .selectWorkspace(index: 8)
            // Cmd+9 replaces core's `last_tab`, whose semantics are "the actual
            // last one", not "index 9". Clamping by index would land on the 9th
            // and leave the last unreachable once there are more than nine.
            case ReservedKeyCode.nine: matched = .selectLastWorkspace
            default: matched = nil
            }
        } else if mods == [.command, .shift] {
            switch keyCode {
            case ReservedKeyCode.leftBracket: matched = .previousTab
            case ReservedKeyCode.rightBracket: matched = .nextTab
            default: matched = nil
            }
        } else if mods == .control {
            matched = keyCode == ReservedKeyCode.tab ? .nextWorkspace : nil
        } else if mods == [.control, .shift] {
            matched = keyCode == ReservedKeyCode.tab ? .previousWorkspace : nil
        } else {
            matched = nil
        }

        guard let matched else { return .unmatched }

        // A repeat is still *ours* — we swallow it so it cannot fall through
        // to a core binding, but we do not execute it again.
        if event.isARepeat { return .consumedRepeat }
        return .action(matched)
    }

    /// Checks whether `event` matches a reserved workspace/tab shortcut and,
    /// if so, performs it against `controller`.
    ///
    /// - Returns: `true` when the event was consumed by this dispatcher and
    ///   must not propagate further. A recognized shortcut is consumed even
    ///   when execution finds nothing to do (e.g. a single-workspace store).
    static func performReservedShortcut(
        _ event: NSEvent,
        keyWindowKind: KeyWindowKind,
        firstResponderIsTextField: Bool,
        controller: TerminalController?
    ) -> Bool {
        switch decision(
            for: event,
            keyWindowKind: keyWindowKind,
            firstResponderIsTextField: firstResponderIsTextField
        ) {
        case .unmatched:
            return false
        case .consumedRepeat:
            return true
        case .action(let action):
            if let controller {
                perform(action, on: controller)
            }
            return true
        }
    }

    /// Applies a recognized action to `controller`'s workspace store,
    /// presenting the result through `selectSession(workspaceID:tabID:)` —
    /// the single entry point for changing what a controller presents.
    static func perform(_ action: Action, on controller: TerminalController) {
        let store = controller.workspaceStore

        switch action {
        case .selectWorkspace(let index):
            let workspaces = store.snapshot.workspaces
            guard !workspaces.isEmpty else { return }
            let clampedIndex = min(max(index, 1), workspaces.count) - 1
            select(workspace: workspaces[clampedIndex], on: controller)

        case .selectLastWorkspace:
            let workspaces = controller.workspaceStore.snapshot.workspaces
            guard let last = workspaces.last else { return }
            select(workspace: last, on: controller)

        case .previousTab:
            moveTab(by: -1, on: controller)

        case .nextTab:
            moveTab(by: 1, on: controller)

        case .previousWorkspace:
            moveWorkspace(by: -1, on: controller)

        case .nextWorkspace:
            moveWorkspace(by: 1, on: controller)
        }
    }

    /// Selects `workspace`, then presents whichever tab is (or becomes) its
    /// selected tab.
    private static func select(workspace: WorkspaceSession, on controller: TerminalController) {
        let store = controller.workspaceStore
        store.selectWorkspace(workspace.id)

        guard let ws = store.snapshot.workspaces.first(where: { $0.id == workspace.id }),
              let tabID = ws.selectedTabID ?? ws.tabs.first?.id else { return }
        controller.selectSession(workspaceID: ws.id, tabID: tabID)
    }

    /// Moves the presented tab within the currently selected workspace by
    /// `delta`, wrapping around at either end.
    private static func moveTab(by delta: Int, on controller: TerminalController) {
        let store = controller.workspaceStore
        let selection = store.snapshot.selection
        guard let ws = store.snapshot.workspaces.first(where: { $0.id == selection.workspaceID }),
              !ws.tabs.isEmpty,
              let currentIndex = ws.tabs.firstIndex(where: { $0.id == selection.tabID }) else { return }

        let count = ws.tabs.count
        let newIndex = ((currentIndex + delta) % count + count) % count
        controller.selectSession(workspaceID: ws.id, tabID: ws.tabs[newIndex].id)
    }

    /// Moves the selected workspace by `delta`, wrapping around at either
    /// end, then presents that workspace's own selected tab.
    private static func moveWorkspace(by delta: Int, on controller: TerminalController) {
        let store = controller.workspaceStore
        let workspaces = store.snapshot.workspaces
        guard !workspaces.isEmpty,
              let currentIndex = workspaces.firstIndex(where: { $0.id == store.snapshot.selection.workspaceID }) else { return }

        let count = workspaces.count
        let newIndex = ((currentIndex + delta) % count + count) % count
        select(workspace: workspaces[newIndex], on: controller)
    }
}
