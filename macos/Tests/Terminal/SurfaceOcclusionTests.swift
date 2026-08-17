import AppKit
import Foundation
import Testing
@testable import Ghostty

/// One window owns every workspace and virtual tab here, so window occlusion
/// alone cannot tell libghostty which surfaces are on screen. A surface behind
/// the presented tab that is never marked hidden keeps its renderer drawing
/// and its Metal drawables allocated for the life of the process.
@MainActor
struct SurfaceOcclusionTests {
    private func makeSession() -> TerminalSessionState {
        let tree: SplitTree<Ghostty.SurfaceView>
        if let app = TerminalControllerTestHarness.sharedApp.app {
            tree = SplitTree(view: Ghostty.SurfaceView(
                app, baseConfig: nil, spawnsSurface: false))
        } else {
            tree = SplitTree<Ghostty.SurfaceView>()
        }
        return TerminalSessionState(id: UUID(), surfaceTree: tree)
    }

    private func makeWorkspace(tabCount: Int) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        return WorkspaceSession(
            id: UUID(),
            name: "Workspace",
            tabs: tabs,
            selectedTabID: tabs.first?.id)
    }

    private func surfaceID(_ session: TerminalSessionState) throws -> UUID {
        try #require(session.surfaceTree.first?.id)
    }

    @Test func onlyThePresentedTabIsReportedVisible() throws {
        let ws = makeWorkspace(tabCount: 3)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws],
            selection: Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)))

        let presented = try surfaceID(ws.tabs[0])
        let hidden = [try surfaceID(ws.tabs[1]), try surfaceID(ws.tabs[2])]

        let visibility = controller.surfaceVisibility(windowVisible: true)
        #expect(visibility[presented] == true)
        for id in hidden {
            #expect(visibility[id] == false)
        }
    }

    @Test func switchingTabsMovesVisibilityToTheIncomingTab() throws {
        let ws = makeWorkspace(tabCount: 2)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws],
            selection: Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)))

        let first = try surfaceID(ws.tabs[0])
        let second = try surfaceID(ws.tabs[1])

        controller.selectSession(workspaceID: ws.id, tabID: ws.tabs[1].id)

        let visibility = controller.surfaceVisibility(windowVisible: true)
        // The outgoing tab must be reported hidden, which is exactly what a
        // presented-tree-only sync used to miss: it stayed visible forever.
        #expect(visibility[first] == false)
        #expect(visibility[second] == true)
    }

    @Test func surfacesInOtherWorkspacesAreHidden() throws {
        let ws1 = makeWorkspace(tabCount: 1)
        let ws2 = makeWorkspace(tabCount: 2)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws1, ws2],
            selection: Selection(workspaceID: ws1.id, tabID: ws1.tabs[0].id)))

        let visibility = controller.surfaceVisibility(windowVisible: true)
        #expect(visibility[try surfaceID(ws1.tabs[0])] == true)
        #expect(visibility[try surfaceID(ws2.tabs[0])] == false)
        #expect(visibility[try surfaceID(ws2.tabs[1])] == false)
        // Every surface the controller owns is accounted for, so none can be
        // left in whatever state it happened to start in.
        #expect(visibility.count == controller.allWorkspaceSurfaces.count)
    }

    @Test func anInvisibleWindowHidesEveryTab() throws {
        let ws = makeWorkspace(tabCount: 2)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [ws],
            selection: Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)))

        let visibility = controller.surfaceVisibility(windowVisible: false)
        #expect(visibility.values.allSatisfy { $0 == false })
        #expect(visibility.isEmpty == false)
    }
}
