import Cocoa
import GhosttyKit

/// Phase 2 controller-construction test seam.
///
/// `TerminalControllerGraphFactory.makeFromWorkspaces(_:selection:)` rebuilds
/// a graph from an already-live hierarchy: nothing is decoded, no surface is
/// created, and no process is spawned. That makes it possible to construct a
/// real, fully-initialized `TerminalController` in a unit test — with a real
/// `workspaceStore`, a real mounted `surfaceTree`, and real
/// `presentedSessionID`/`presentedMountGeneration` bookkeeping — without a
/// run loop or a spawned process.
///
/// Construction is NOT window-free, despite what this doc previously
/// claimed: `BaseTerminalController.init` mounts the initial `surfaceTree`,
/// whose `didSet` walks into window-facing code that reaches `self.window`,
/// and `TerminalController.windowNibName` is non-nil by default. That
/// combination calls `loadWindow()` and instantiates a REAL `TerminalWindow`
/// backed by the "Terminal" nib, which then registers itself in
/// `NSApp.windows` -> `TerminalController.all` -> `preferredParent`. Left
/// alone across many tests in the same process, those windows accumulate.
///
/// The harness deliberately does NOT close them. `NSWindow.close()` drives
/// `windowWillClose`, which unregisters the controller and tears its sessions
/// down — and a prior test's controller is often still held and asserted
/// against, so closing here crashed the whole test host mid-suite. The
/// accumulation is inert by comparison; what it costs is that a test must not
/// depend on `TerminalController.all` or `preferredParent` being empty, since
/// controllers from earlier tests are still in there. Resolve explicitly
/// against the controller the harness returned instead.
///
/// This is what lets tests assert what is actually PRESENTED on the
/// controller rather than only the store's desired selection.
enum TerminalControllerTestHarness {
    /// A headless `Ghostty.App` shared across harness-built controllers.
    ///
    /// `makeFromWorkspaces` never touches `ghostty.app` (no surface is
    /// created), so a single shared instance safely backs every controller
    /// this harness builds; constructing a fresh native app per test would be
    /// needlessly expensive and is not required for correctness.
    @MainActor
    static let sharedApp = Ghostty.App()

    /// Builds a `TerminalController` directly from a live workspace
    /// hierarchy, mirroring what `TerminalController.init(_:with:)` (window
    /// close undo) does with an already-live graph.
    ///
    /// Returns `nil` under the same conditions `makeFromWorkspaces` does: an
    /// empty `workspaces` array, or a selection that cannot be resolved to
    /// any tab in any workspace.
    /// `restoredPhysicalUUID` mirrors what `TerminalWindowRestoration`
    /// passes when rehydrating a saved window; nil builds a genuinely new
    /// one.
    @MainActor
    static func make(
        workspaces: [WorkspaceSession],
        selection: Selection,
        restoredPhysicalUUID: UUID? = nil
    ) -> TerminalController? {
        guard let graph = TerminalControllerGraphFactory.makeFromWorkspaces(
            workspaces,
            selection: selection
        ) else { return nil }

        return TerminalController(
            sharedApp,
            graph: graph,
            restoredPhysicalUUID: restoredPhysicalUUID)
    }
}
