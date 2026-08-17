import Cocoa
import GhosttyKit

/// Controller-construction test seam.
///
/// `TerminalControllerGraphFactory.makeFromWorkspaces(_:selection:)` rebuilds
/// a graph from an already-live hierarchy: nothing is decoded, no surface is
/// created, and no process is spawned. That makes it possible to construct a
/// real, fully-initialized `TerminalController` in a unit test — with a real
/// `workspaceStore`, a real mounted `surfaceTree`, and real
/// `presentedSessionID`/`presentedMountGeneration` bookkeeping — without a
/// run loop or a spawned process.
///
/// Construction is NOT window-free: `BaseTerminalController.init` mounts the
/// initial `surfaceTree`, whose `didSet` walks into window-facing code that
/// reaches `self.window`,
/// and `TerminalController.windowNibName` is non-nil by default. That
/// combination calls `loadWindow()` and instantiates a REAL `TerminalWindow`
/// backed by the "Terminal" nib, which then registers itself in
/// `NSApp.windows` -> `TerminalController.all` -> `preferredParent`. Left
/// alone across many tests in the same process, those windows accumulate.
///
/// The windows themselves are cheap. What is not cheap is a live
/// `Ghostty.SurfaceView` under one: it owns a real PTY plus a renderer thread
/// and three IO threads, and around forty of them starve the test host's main
/// run loop. So a test that only needs the object graph must build its views
/// with `Ghostty.SurfaceView(app, baseConfig:, spawnsSurface: false)`, which
/// never asks libghostty for a surface. Only a test that genuinely exercises
/// a terminal creates a real one, and it closes that surface itself.
///
/// The harness offers no teardown helper because a live surface cannot be
/// released after the fact: `DetachedUndoLease` and `ClosedTabHistory` keep
/// owning detached surfaces, so closing the window, freeing the surface, or
/// dropping the last reference all reach freed state from the undo/redo paths
/// and take the test host down. Releasing one would require those two types
/// to own surface lifetime explicitly first.
///
/// A test must not depend on `TerminalController.all` or `preferredParent`
/// being empty, since controllers from earlier tests are still in there.
/// Resolve explicitly against the controller the harness returned instead.
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
