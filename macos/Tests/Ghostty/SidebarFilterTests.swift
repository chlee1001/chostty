import AppKit
import Combine
import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

/// Tests for the presentation-only sidebar features:
///
/// - The pure `SidebarFilter.filter`/`effectiveCollapsed`, plus proof
///   that filtering a 200-tab store never calls the synchronous
///   `GitBranchResolver.branch(for:)` filesystem walk.
/// - The pure `SidebarPolicy.shouldFlatten` predicate.
/// - "Collapse All"/"Expand All" are exactly the store calls the
///   empty-area context menu wires up, and each is a single validated commit
///   that leaves the selected workspace expanded.
@MainActor
struct SidebarFilterTests {
    // MARK: - Fixtures

    private func makeSession(title: String = "", pwd: String? = nil, titleOverride: String? = nil) -> TerminalSessionState {
        let session = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        session.title = title
        session.pwd = pwd
        session.titleOverride = titleOverride
        return session
    }

    private func makeWorkspace(name: String, tabs: [TerminalSessionState]) -> WorkspaceSession {
        WorkspaceSession(id: UUID(), name: name, tabs: tabs, selectedTabID: tabs.first?.id)
    }

    /// Builds a store with `tabCount` tabs in a single workspace, matching
    /// the pattern in `WorkspaceStoreTransactionTests`.
    private func makeStore(tabCount: Int) -> WorkspaceSessionStore {
        let initial = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let store = WorkspaceSessionStore(initialSession: initial)
        for _ in 1..<max(tabCount, 1) {
            store.addTab(TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>()))
        }
        return store
    }

    // MARK: - SidebarFilter.filter

    @Test func emptyQueryReturnsWorkspacesUnchanged() {
        let workspaces = [
            makeWorkspace(name: "alpha", tabs: [makeSession(title: "one")]),
            makeWorkspace(name: "beta", tabs: [makeSession(title: "two")]),
        ]
        #expect(SidebarFilter.filter(workspaces: workspaces, query: "").map(\.id) == workspaces.map(\.id))
        #expect(SidebarFilter.filter(workspaces: workspaces, query: "   ").map(\.id) == workspaces.map(\.id))
    }

    @Test func filterMatchesWorkspaceName() {
        let target = makeWorkspace(name: "Backend", tabs: [makeSession()])
        let other = makeWorkspace(name: "Frontend UI", tabs: [makeSession()])
        let result = SidebarFilter.filter(workspaces: [target, other], query: "back")
        #expect(result.map(\.id) == [target.id])
    }

    @Test func filterMatchesTabTitle() {
        let session = makeSession(title: "npm run dev")
        let ws = makeWorkspace(name: "misc", tabs: [session])
        let other = makeWorkspace(name: "other", tabs: [makeSession(title: "vim")])
        let result = SidebarFilter.filter(workspaces: [ws, other], query: "npm")
        #expect(result.map(\.id) == [ws.id])
    }

    @Test func filterMatchesTitleOverride() {
        let session = makeSession(title: "zsh", titleOverride: "deploy script")
        let ws = makeWorkspace(name: "misc", tabs: [session])
        let other = makeWorkspace(name: "other", tabs: [makeSession(title: "vim")])
        let result = SidebarFilter.filter(workspaces: [ws, other], query: "deploy")
        #expect(result.map(\.id) == [ws.id])
    }

    @Test func filterMatchesPwd() {
        let session = makeSession(title: "zsh", pwd: "/Users/me/Projects/chostty")
        let ws = makeWorkspace(name: "misc", tabs: [session])
        let other = makeWorkspace(name: "other", tabs: [makeSession(title: "vim", pwd: "/tmp")])
        let result = SidebarFilter.filter(workspaces: [ws, other], query: "chostty")
        #expect(result.map(\.id) == [ws.id])
    }

    @Test func filterIsCaseInsensitiveAndScopedGlobally() {
        let session = makeSession(title: "Deploy")
        let ws = makeWorkspace(name: "misc", tabs: [session])
        #expect(SidebarFilter.filter(workspaces: [ws], query: "DEPLOY").map(\.id) == [ws.id])
        #expect(SidebarFilter.filter(workspaces: [ws], query: "nomatch").isEmpty)
    }

    // MARK: - effectiveCollapsed

    @Test func effectiveCollapsedIsVisualOnlyAndAutoExpandsWhileFiltering() {
        // Collapsed + empty query: stays collapsed exactly as today.
        #expect(SidebarFilter.effectiveCollapsed(isCollapsed: true, query: "") == true)
        // Collapsed + active query: renders expanded so a buried match shows.
        #expect(SidebarFilter.effectiveCollapsed(isCollapsed: true, query: "abc") == false)
        // Not collapsed: stays expanded regardless of query.
        #expect(SidebarFilter.effectiveCollapsed(isCollapsed: false, query: "abc") == false)
        #expect(SidebarFilter.effectiveCollapsed(isCollapsed: false, query: "") == false)
    }

    @Test func collapsedWorkspaceWithMatchStillRendersItsTabsWhileFiltering() {
        let session = makeSession(title: "target")
        var ws = makeWorkspace(name: "misc", tabs: [session])
        ws.isCollapsed = true

        // The row would hide its tabs (`isCollapsed`), but `effectiveCollapsed`
        // says otherwise once a query is active, so the match stays visible.
        #expect(ws.isCollapsed == true)
        #expect(SidebarFilter.effectiveCollapsed(isCollapsed: ws.isCollapsed, query: "target") == false)
    }

    // MARK: - Never calls the synchronous git resolver on the typing path

    @Test func filteringA200TabStoreNeverCallsTheSynchronousGitResolver() {
        let store = makeStore(tabCount: 200)
        let before = GitBranchResolver.callCount

        // Simulate typing progressively longer queries, exactly like the
        // sidebar header field would drive `SidebarFilter.filter` on every
        // keystroke.
        for query in ["a", "ab", "abc", "abcd", ""] {
            _ = SidebarFilter.filter(workspaces: store.snapshot.workspaces, query: query)
        }

        #expect(GitBranchResolver.callCount == before)
    }
    /// The actual acceptance: typing a filter query must never touch the
    /// store. `SidebarFilter.filter` operates on `store.snapshot.workspaces`
    /// as a plain value — it never calls anything on `store` itself — so
    /// driving several queries through it must produce ZERO
    /// `$snapshot` emissions and leave `mountGeneration` unchanged. Mirrors
    /// the `store.$snapshot.dropFirst().sink` idiom from
    /// `WorkspaceStoreTransactionTests`.
    @Test func typingFilterQueriesEmitsNoSnapshotEventsAndNoGenerationChange() {
        let store = makeStore(tabCount: 50)
        var events = 0
        let cancellable = store.$snapshot.dropFirst().sink { _ in events += 1 }
        defer { cancellable.cancel() }

        let before = store.snapshot.mountGeneration

        for query in ["", "a", "ab", "abc", "nomatch", ""] {
            _ = SidebarFilter.filter(workspaces: store.snapshot.workspaces, query: query)
        }

        #expect(events == 0)
        #expect(store.snapshot.mountGeneration == before)
    }

    // MARK: - SidebarPolicy.shouldFlatten

    @Test func shouldFlattenOnlyForExactlyOneWorkspaceUnderFlattenPolicy() {
        #expect(SidebarPolicy.shouldFlatten(workspaceCount: 1, policy: .flatten) == true)
        #expect(SidebarPolicy.shouldFlatten(workspaceCount: 2, policy: .flatten) == false)
        #expect(SidebarPolicy.shouldFlatten(workspaceCount: 0, policy: .flatten) == false)
        #expect(SidebarPolicy.shouldFlatten(workspaceCount: 1, policy: .alwaysGrouped) == false)
        #expect(SidebarPolicy.shouldFlatten(workspaceCount: 2, policy: .alwaysGrouped) == false)
    }

    @Test func policyToggleFlipsBetweenTheTwoValues() {
        #expect(SidebarSingleWorkspacePolicy.flatten.toggled == .alwaysGrouped)
        #expect(SidebarSingleWorkspacePolicy.alwaysGrouped.toggled == .flatten)
    }

    // MARK: - "Collapse All"/"Expand All" action wiring

    /// The empty-area menu's "Collapse All" item calls
    /// `store.collapseAllExceptSelected()` directly — this test exercises
    /// that exact call and asserts the acceptance criterion: one generation
    /// bump, and the presented workspace stays expanded.
    @Test func collapseAllLeavesSelectedWorkspaceExpandedWithOneGenerationBump() {
        let store = makeStore(tabCount: 1)
        let firstWorkspace = store.snapshot.selection.workspaceID
        let second = store.addWorkspace(initialSession: makeSession(title: "second"))
        let third = store.addWorkspace(initialSession: makeSession(title: "third"))
        store.selectWorkspace(firstWorkspace)

        let before = store.snapshot.mountGeneration
        store.collapseAllExceptSelected()

        #expect(store.snapshot.mountGeneration == before + 1)
        let selected = store.snapshot.workspaces.first { $0.id == firstWorkspace }
        #expect(selected?.isCollapsed == false)
        for id in [second, third] {
            #expect(store.snapshot.workspaces.first { $0.id == id }?.isCollapsed == true)
        }
    }

    @Test func expandAllExpandsEveryWorkspaceWithOneGenerationBump() {
        let store = makeStore(tabCount: 1)
        let firstWorkspace = store.snapshot.selection.workspaceID
        let second = store.addWorkspace(initialSession: makeSession(title: "second"))
        store.selectWorkspace(firstWorkspace)
        store.collapseAllExceptSelected()

        let before = store.snapshot.mountGeneration
        store.expandAll()

        #expect(store.snapshot.mountGeneration == before + 1)
        #expect(store.snapshot.workspaces.allSatisfy { !$0.isCollapsed })
        _ = second
    }
}
