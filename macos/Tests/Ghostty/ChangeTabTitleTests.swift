import AppKit
import Testing
@testable import Ghostty

/// Architect re-review regression: "Change Tab Title" (`promptTabTitle()`,
/// and the `set_tab_title` AppleScript/escape-sequence handler in
/// `Ghostty.App.swift`) used to write only the controller-level
/// `titleOverride`, which drives `applyTitleToWindow()` (the WINDOW title)
/// but is never read by the tab strip (`VirtualTabBar`) or the sidebar
/// (`SidebarView`) — both read `session.titleOverride`, written by
/// `WorkspaceSessionStore.renameTab`. So the menu item renamed the window,
/// not the presented tab.
///
/// These tests exercise the fixed write path directly (`renameTab` +
/// `applyTitleToWindow`, exactly what `promptTabTitle`'s alert completion
/// handler and the `set_tab_title` handler now do) rather than driving the
/// `NSAlert` sheet, which -- like other confirmation sheets in this suite --
/// never resolves synchronously in a headless test host.
@MainActor
struct ChangeTabTitleTests {
    private func makeSession() -> TerminalSessionState {
        let tree: SplitTree<Ghostty.SurfaceView>
        if let app = TerminalControllerTestHarness.sharedApp.app {
            tree = SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil))
        } else {
            tree = SplitTree<Ghostty.SurfaceView>()
        }
        return TerminalSessionState(id: UUID(), surfaceTree: tree)
    }

    private func makeWorkspace(tabCount: Int) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        return WorkspaceSession(id: UUID(), name: "Workspace", tabs: tabs, selectedTabID: tabs.first?.id)
    }

    /// Renaming the PRESENTED tab must change `session.titleOverride` (what
    /// the tab strip and sidebar read), not merely the window title.
    @Test func renamingPresentedTabChangesSessionTitleOverride() throws {
        let ws = makeWorkspace(tabCount: 2)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        let presentedID = try #require(controller.presentedSessionID)
        #expect(presentedID == ws.tabs[0].id)

        // What `promptTabTitle`'s alert completion (and the `set_tab_title`
        // handler) now do on "OK".
        controller.workspaceStore.renameTab(presentedID, to: "Deploy Logs")
        controller.applyTitleToWindow()

        // The tab strip/sidebar source of truth changed.
        #expect(ws.tabs[0].titleOverride == "Deploy Logs")
        // The OTHER tab is untouched.
        #expect(ws.tabs[1].titleOverride == nil)
        // The window title (derived) follows the presented session's override.
        #expect(controller.window?.title == "Deploy Logs")
    }

    /// The override must NOT stick across tab switches: `selectSession`
    /// re-derives the window title from whichever session becomes presented,
    /// so an unrelated tab without its own override shows its own title, not
    /// the previous tab's renamed title.
    @Test func overrideDoesNotStickAcrossTabSwitch() throws {
        let ws = makeWorkspace(tabCount: 2)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))

        let firstID = ws.tabs[0].id
        let secondID = ws.tabs[1].id

        controller.workspaceStore.renameTab(firstID, to: "Renamed First")
        controller.applyTitleToWindow()
        #expect(controller.window?.title == "Renamed First")

        controller.selectSession(workspaceID: ws.id, tabID: secondID)

        #expect(controller.presentedSessionID == secondID)
        // The second tab has no override of its own, so the window title
        // must NOT still read "Renamed First".
        #expect(controller.window?.title != "Renamed First")
        // The first tab's own override is untouched by switching away.
        #expect(ws.tabs[0].titleOverride == "Renamed First")
    }

    /// Clearing the title (empty string, "Leave blank to restore the
    /// default") clears the session override, same as the tab strip's own
    /// "Reset Name" entry.
    @Test func emptyTitleClearsSessionOverride() throws {
        let ws = makeWorkspace(tabCount: 1)
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        let controller = try #require(TerminalControllerTestHarness.make(workspaces: [ws], selection: selection))
        let presentedID = try #require(controller.presentedSessionID)

        controller.workspaceStore.renameTab(presentedID, to: "Temp")
        #expect(ws.tabs[0].titleOverride == "Temp")

        controller.workspaceStore.renameTab(presentedID, to: "")
        controller.applyTitleToWindow()
        #expect(ws.tabs[0].titleOverride == nil)
    }
}
