import AppKit
import Testing
@testable import Ghostty

/// Tests for `TerminalController.canCloseOtherTabs(tabs:)` and
/// `TerminalController.canCloseTabsOnTheRight(tabs:selectedTabID:)` — the pure,
/// window-free predicates `validateMenuItem` and the VirtualTabBar item's
/// context menu both gate on, per the architect finding that
/// `closeOtherTabs` had no `validateMenuItem` case at all (inheriting
/// `default: return true` and validating ENABLED on a 1-tab workspace) and
/// that neither predicate had been extracted as a directly-testable
/// window-free function.
@MainActor
struct MenuValidationPredicateTests {
    private func makeSession() -> TerminalSessionState {
        TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
    }

    private func makeTabs(_ count: Int) -> [TerminalSessionState] {
        (0..<count).map { _ in makeSession() }
    }

    // MARK: - canCloseOtherTabs

    @Test func canCloseOtherTabsIsFalseOnASingleTabWorkspace() {
        let tabs = makeTabs(1)
        #expect(TerminalController.canCloseOtherTabs(tabs: tabs) == false)
    }

    @Test func canCloseOtherTabsIsTrueOnATwoTabWorkspace() {
        let tabs = makeTabs(2)
        #expect(TerminalController.canCloseOtherTabs(tabs: tabs) == true)
    }

    @Test func canCloseOtherTabsIsTrueOnAFourTabWorkspace() {
        let tabs = makeTabs(4)
        #expect(TerminalController.canCloseOtherTabs(tabs: tabs) == true)
    }

    // MARK: - canCloseTabsOnTheRight: 1 tab

    @Test func canCloseTabsOnTheRightIsFalseOnASingleTabWorkspace() {
        let tabs = makeTabs(1)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[0].id) == false)
    }

    // MARK: - canCloseTabsOnTheRight: 2 tabs

    @Test func canCloseTabsOnTheRightIsTrueWhenFirstOfTwoIsSelected() {
        let tabs = makeTabs(2)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[0].id) == true)
    }

    @Test func canCloseTabsOnTheRightIsFalseWhenLastOfTwoIsSelected() {
        let tabs = makeTabs(2)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[1].id) == false)
    }

    // MARK: - canCloseTabsOnTheRight: 4 tabs, first/middle/last selection

    @Test func canCloseTabsOnTheRightIsTrueWhenFirstOfFourIsSelected() {
        let tabs = makeTabs(4)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[0].id) == true)
    }

    @Test func canCloseTabsOnTheRightIsTrueWhenMiddleOfFourIsSelected() {
        let tabs = makeTabs(4)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[1].id) == true)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[2].id) == true)
    }

    @Test func canCloseTabsOnTheRightIsFalseWhenLastOfFourIsSelected() {
        let tabs = makeTabs(4)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: tabs[3].id) == false)
    }

    // MARK: - Edge cases

    @Test func canCloseTabsOnTheRightIsFalseWhenSelectedTabIDIsNil() {
        let tabs = makeTabs(4)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: nil) == false)
    }

    @Test func canCloseTabsOnTheRightIsFalseWhenSelectedTabIDIsNotInTabs() {
        let tabs = makeTabs(4)
        #expect(TerminalController.canCloseTabsOnTheRight(tabs: tabs, selectedTabID: UUID()) == false)
    }
}
