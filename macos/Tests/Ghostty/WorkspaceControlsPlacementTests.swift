import Testing
@testable import Ghostty

/// Where the workspace controls (sidebar toggle, "+", actions menu) render.
///
/// A window state that resolved to `.titlebarAccessory` when the titlebar
/// cannot show one leaves the controls invisible, and with the sidebar closed
/// that leaves `⌘B` as the only way back.
///
/// `TerminalController.computeWorkspaceControlsPlacement()` feeds live window
/// state into `forStandaloneWindow`. Hosting an on-screen window here is not an
/// option (see `SidebarEmptyAreaMenuTests`), so the decision is pure and these
/// tests cover its matrix.
struct WorkspaceControlsPlacementTests {
    /// The ordinary case: a titled, windowed terminal puts the controls in the
    /// titlebar, next to the traffic lights.
    @Test(arguments: [
        Ghostty.Config.MacOSTitlebarStyle.transparent,
        .native,
        .tabs,
    ])
    func titledWindowedUsesTheTitlebarAccessory(style: Ghostty.Config.MacOSTitlebarStyle) {
        #expect(WorkspaceControlsPlacement.forStandaloneWindow(
            isTitled: true,
            isFullscreen: false,
            titlebarStyle: style) == .titlebarAccessory)
    }

    /// Native fullscreen keeps `.titled`, so the style mask alone still reports a
    /// titlebar. It is moved into an auto-hiding overlay, which is why
    /// `isFullscreen` has to be consulted separately.
    @Test func nativeFullscreenUsesTheStripEvenThoughItIsStillTitled() {
        #expect(WorkspaceControlsPlacement.forStandaloneWindow(
            isTitled: true,
            isFullscreen: true,
            titlebarStyle: .transparent) == .contentStrip)
    }

    /// Non-native fullscreen removes `.titled` outright, and removing it also
    /// derefs every titlebar accessory (see `Fullscreen.swift`).
    @Test func nonNativeFullscreenUsesTheStrip() {
        #expect(WorkspaceControlsPlacement.forStandaloneWindow(
            isTitled: false,
            isFullscreen: false,
            titlebarStyle: .transparent) == .contentStrip)
    }

    /// `window-decorations = false` drops `.titled` at window creation, so there
    /// is never a titlebar to attach anything to.
    @Test func undecoratedWindowUsesTheStrip() {
        #expect(WorkspaceControlsPlacement.forStandaloneWindow(
            isTitled: false,
            isFullscreen: false,
            titlebarStyle: .native) == .contentStrip)
    }

    /// `macos-titlebar-style = hidden` exists to remove window chrome, and it
    /// hides the traffic lights along with the titlebar container. A strip there
    /// would hand back the row the user turned off, so the controls stay in the
    /// sidebar header instead.
    @Test(arguments: [false, true])
    func hiddenTitlebarStyleKeepsTheControlsInTheSidebarHeader(isFullscreen: Bool) {
        #expect(WorkspaceControlsPlacement.forStandaloneWindow(
            isTitled: true,
            isFullscreen: isFullscreen,
            titlebarStyle: .hidden) == .sidebarHeader)
    }

    /// Losing `.titled` outranks the titlebar style: a non-native fullscreen
    /// window has no titlebar at all, so the strip is the only host left even
    /// under the hidden style.
    @Test func untitledWindowUsesTheStripEvenUnderTheHiddenTitlebarStyle() {
        #expect(WorkspaceControlsPlacement.forStandaloneWindow(
            isTitled: false,
            isFullscreen: false,
            titlebarStyle: .hidden) == .contentStrip)
    }

    /// The two hosts must never both show the buttons: the titlebar that slides
    /// down over native fullscreen would otherwise duplicate the strip's row.
    @Test func onlyTheTitlebarPlacementShowsTheAccessory() {
        #expect(WorkspaceControlsPlacement.titlebarAccessory.showsTitlebarAccessory)
        #expect(!WorkspaceControlsPlacement.contentStrip.showsTitlebarAccessory)
        #expect(!WorkspaceControlsPlacement.sidebarHeader.showsTitlebarAccessory)
    }
}
