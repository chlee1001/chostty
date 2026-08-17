import AppKit
import Testing
@testable import Ghostty

/// Tests for `TerminalEntity.owningWorkspaceName(for:controllers:)` — the
/// controller-taking seam extracted from the `NSApp.windows`-reading
/// production path so this resolution logic is testable without real
/// on-screen windows.
///
/// Built through `TerminalControllerTestHarness` so a surface belonging to a
/// NON-presented tab (reachable only via `allWorkspaceSurfaces`) can be
/// resolved back to its owning workspace's name, mirroring how a
/// `TerminalEntity` built from `TerminalQuery.all` must behave for App
/// Intents.
@MainActor
struct TerminalEntityWorkspaceNameTests {
    private func makeSession() -> TerminalSessionState {
        let tree: SplitTree<Ghostty.SurfaceView>
        if let app = TerminalControllerTestHarness.sharedApp.app {
            tree = SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false))
        } else {
            tree = SplitTree<Ghostty.SurfaceView>()
        }
        return TerminalSessionState(id: UUID(), surfaceTree: tree)
    }

    private func makeWorkspace(name: String, tabCount: Int) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        return WorkspaceSession(id: UUID(), name: name, tabs: tabs, selectedTabID: tabs.first?.id)
    }

    /// A surface in workspace 2's NON-presented tab still resolves to
    /// workspace 2's name — the whole point of walking every live
    /// controller's store rather than trusting `view.window`, which is nil
    /// for a surface whose tab is not currently mounted.
    @Test func surfaceInNonPresentedTabOfSecondWorkspaceResolvesItsName() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 1)
        let ws2 = makeWorkspace(name: "Bravo", tabCount: 1)
        let selection = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: selection))
        #expect(controller.presentedSessionID == ws1.tabs[0].id)

        let ws2Surface = try #require(ws2.tabs[0].surfaceTree.first)

        let name = TerminalEntity.owningWorkspaceName(for: ws2Surface, controllers: [controller])
        #expect(name == "Bravo")
    }

    /// A surface that belongs to none of the given controllers resolves to
    /// `nil` rather than falling back to some other workspace's name.
    ///
    /// Uses a second harness-registered controller (not an unregistered
    /// orphan surface) as the "not owned" case: an orphan `Ghostty.SurfaceView`
    /// created outside any `TerminalControllerTestHarness` graph spawns a
    /// real PTY that is never registered with `SurfaceOwnerRegistry`, and
    /// tearing it down outside that lifecycle crashes the test host.
    @Test func surfaceNotOwnedByAnyControllerResolvesNil() throws {
        let ws1 = makeWorkspace(name: "Alpha", tabCount: 1)
        let selection1 = Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)
        let controller1 = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1],
            selection: selection1))

        let ws2 = makeWorkspace(name: "Bravo", tabCount: 1)
        let selection2 = Selection(workspaceID: ws2.id, tabID: ws2.tabs[0].id)
        let controller2 = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws2],
            selection: selection2))

        let ws1Surface = try #require(ws1.tabs[0].surfaceTree.first)

        // controller2 does not own ws1's surface; querying against only
        // controller2 must resolve nil rather than falling back to
        // controller2's own workspace name.
        let name = TerminalEntity.owningWorkspaceName(for: ws1Surface, controllers: [controller2])
        #expect(name == nil)
        _ = controller1
    }
}