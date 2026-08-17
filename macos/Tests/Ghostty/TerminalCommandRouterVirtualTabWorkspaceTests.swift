import AppKit
import Testing
@testable import Ghostty

/// Regression coverage for an architecture review finding: `createVirtualTab` used
/// `source` only to resolve the owning CONTROLLER, then read
/// `controller.workspaceStore.selectedWorkspace` for both the inherited
/// config and the destination workspace. A `new_tab` whose `source` surface
/// lived in a non-selected workspace therefore landed in whichever workspace
/// happened to be selected, picking up the wrong `defaultDirectory`.
///
/// Built through `TerminalControllerTestHarness` + a real `SurfaceOwnerRegistry`
/// entry so `TerminalCommandRouter.createVirtualTab` resolves both the owning
/// controller AND the owning workspace exactly as it does live.
@MainActor
struct TerminalCommandRouterVirtualTabWorkspaceTests {
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

    @Test func newTabFromSurfaceInNonSelectedWorkspaceLandsInThatSurfacesWorkspace() throws {
        let selectedWs = makeWorkspace(name: "Selected", tabCount: 1)
        let sourceWs = makeWorkspace(name: "Source", tabCount: 1)
        let selection = Selection(workspaceID: selectedWs.id, tabID: selectedWs.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [selectedWs, sourceWs],
            selection: selection))

        // The source surface lives in the NON-selected workspace and is not
        // presented — its `.window` is nil, so the registry (not the
        // window-fallback) is what must resolve the owning controller.
        let sourceSurface = try #require(sourceWs.tabs[0].surfaceTree.first)
        #expect(sourceSurface.window == nil)

        let registry = SurfaceOwnerRegistry()
        registry.register(SurfaceOwnerLocation(
            controllerID: ObjectIdentifier(controller),
            workspaceID: sourceWs.id,
            tabID: sourceWs.tabs[0].id,
            surfaceID: sourceSurface.id))
        let dispatcher = SurfaceEventDispatcher()
        dispatcher.registry = registry
        let router = TerminalCommandRouter()
        router.dispatcher = dispatcher

        let beforeGeneration = controller.workspaceStore.snapshot.mountGeneration

        let resolved = try #require(router.createVirtualTab(source: sourceSurface))
        #expect(resolved === controller)

        // Lands in the SOURCE surface's workspace, not the one that happened
        // to be selected.
        let selectionAfter = controller.workspaceStore.snapshot.selection
        #expect(selectionAfter.workspaceID == sourceWs.id)
        let landedWorkspace = try #require(controller.workspaceStore.workspace(forTabID: selectionAfter.tabID))
        #expect(landedWorkspace.id == sourceWs.id)
        #expect(landedWorkspace.tabs.count == 2)

        // Exactly one generation bump for the whole operation.
        #expect(controller.workspaceStore.snapshot.mountGeneration == beforeGeneration + 1)
    }
}
