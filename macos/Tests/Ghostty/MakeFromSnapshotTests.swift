import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Boot-graph tests. Surface creation is injected with `spawnsSurface: false`,
/// so the whole graph is built without starting a terminal.
@MainActor
@Suite struct MakeFromSnapshotTests {
    // MARK: - Fixtures

    private func makeLeaf(cwd: String? = nil) -> PaneLeafSnapshot {
        PaneLeafSnapshot(uuid: UUID(), cwd: cwd, title: nil)
    }

    private func makeTab(panes: Int = 1, cwd: String? = nil) -> TabSnapshot {
        var tree: PaneTreeSnapshot = .leaf(makeLeaf(cwd: cwd))
        for _ in 1..<max(panes, 1) {
            tree = .split(direction: .horizontal, ratio: 0.5, left: tree, right: .leaf(makeLeaf(cwd: cwd)))
        }
        return TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: tree,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
    }

    private func makeWindow(
        workspaces: [WorkspaceSnapshot],
        selecting selection: SelectionSnapshot? = nil
    ) -> WindowSnapshot {
        WindowSnapshot(
            physicalUUID: UUID(),
            selection: selection ?? workspaces.first.flatMap { ws in
                ws.selectedTabID.map { SelectionSnapshot(workspaceID: ws.id, tabID: $0) }
            },
            workspaces: workspaces
        )
    }

    private func makeWorkspace(
        tabs: [TabSnapshot],
        name: String = "Workspace 1",
        defaultDirectory: String? = nil,
        color: TerminalTabColor = .none,
        isCollapsed: Bool = false
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: UUID(),
            name: name,
            color: color,
            isCollapsed: isCollapsed,
            defaultDirectory: defaultDirectory,
            tabs: tabs,
            selectedTabID: tabs.first?.id
        )
    }

    private func inertFactory() -> (PaneLeafSnapshot, WorkspaceSnapshot) -> Ghostty.SurfaceView? {
        { leaf, _ in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: leaf.uuid, spawnsSurface: false)
            view.pwd = leaf.cwd
            return view
        }
    }

    private func build(
        _ window: WindowSnapshot,
        registry: PendingHydrationRegistry
    ) -> TerminalControllerGraphFactory.InitialGraph? {
        TerminalControllerGraphFactory.makeFromSnapshot(
            ghostty: TerminalControllerTestHarness.sharedApp,
            window: window,
            registry: registry,
            makeSurface: inertFactory()
        )
    }

    // MARK: - Lazy hydration boundary

    @Test func onlyTheSelectedTabIsMaterialized() throws {
        let selected = makeTab(panes: 2)
        let other = makeTab(panes: 3)
        let secondWorkspace = makeWorkspace(tabs: [makeTab(panes: 2)], name: "Workspace 2")
        let workspace = makeWorkspace(tabs: [selected, other])
        let window = makeWindow(
            workspaces: [workspace, secondWorkspace],
            selecting: SelectionSnapshot(workspaceID: workspace.id, tabID: selected.id)
        )

        let registry = PendingHydrationRegistry()
        let graph = try #require(build(window, registry: registry))

        #expect(graph.initialSession.id == selected.id)
        #expect(Array(graph.initialSurfaceTree).count == 2)

        let sessions = graph.store.allSessions
        for session in sessions where session.id != selected.id {
            #expect(session.surfaceTree.isEmpty)
        }
    }

    @Test func everyUnselectedTabIsRecordedAsPending() throws {
        let selected = makeTab()
        let workspace = makeWorkspace(tabs: [selected, makeTab(panes: 2), makeTab(panes: 3)])
        let second = makeWorkspace(tabs: [makeTab(), makeTab()], name: "Workspace 2")
        let window = makeWindow(
            workspaces: [workspace, second],
            selecting: SelectionSnapshot(workspaceID: workspace.id, tabID: selected.id)
        )

        let registry = PendingHydrationRegistry()
        _ = try #require(build(window, registry: registry))

        // Five tabs total, one of which is live.
        #expect(registry.count == 4)
        #expect(!registry.contains(selected.id))
        #expect(registry.snapshot(for: workspace.tabs[1].id)?.paneTree?.paneCount == 2)
        #expect(registry.snapshot(for: workspace.tabs[2].id)?.paneTree?.paneCount == 3)
    }

    // MARK: - Identity and metadata

    @Test func windowTabAndPaneIdentityAreReusedNotMinted() throws {
        let leafID = UUID()
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: "server",
            tabColor: "#123456",
            paneTree: .leaf(PaneLeafSnapshot(uuid: leafID, cwd: nil, title: nil)),
            focusedPaneID: leafID,
            zoomedPaneID: nil
        )
        let workspace = makeWorkspace(tabs: [tab])
        let window = makeWindow(workspaces: [workspace])

        let graph = try #require(build(window, registry: PendingHydrationRegistry()))

        #expect(graph.physicalUUID == window.physicalUUID)
        #expect(graph.initialSession.id == tab.id)
        #expect(graph.initialSurfaceTree.first?.id == leafID)
        #expect(graph.initialSession.focusedSurfaceID == leafID)
        #expect(graph.focusedSurface?.id == leafID)
        #expect(graph.initialSession.titleOverride == "server")
        #expect(graph.initialSession.tabColor == "#123456")
    }

    /// A tab that has not been hydrated yet still has to read correctly in the
    /// sidebar. Without seeding, every unopened tab lists as the placeholder
    /// title with no directory, even though the snapshot carries both.
    @Test func pendingTabsShowTheirStoredTitleAndDirectory() throws {
        let selected = makeTab()
        let pendingLeaf = PaneLeafSnapshot(
            uuid: UUID(),
            cwd: "/Users/someone/Documents/NoMachine",
            title: "someone@host:~/Documents/NoMachine"
        )
        let pending = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .leaf(pendingLeaf),
            focusedPaneID: pendingLeaf.uuid,
            zoomedPaneID: nil
        )
        let workspace = makeWorkspace(tabs: [selected, pending])
        let window = makeWindow(
            workspaces: [workspace],
            selecting: SelectionSnapshot(workspaceID: workspace.id, tabID: selected.id)
        )

        let graph = try #require(build(window, registry: PendingHydrationRegistry()))
        let restored = try #require(graph.store.allSessions.first { $0.id == pending.id })

        #expect(restored.surfaceTree.isEmpty)
        #expect(restored.title == "someone@host:~/Documents/NoMachine")
        #expect(restored.pwd == "/Users/someone/Documents/NoMachine")
    }

    /// The seed follows the focused pane, which is the same one the live
    /// subscription treats as representative once the tab hydrates.
    @Test func seededTitleComesFromTheFocusedPane() throws {
        let first = PaneLeafSnapshot(uuid: UUID(), cwd: "/first", title: "first pane")
        let focused = PaneLeafSnapshot(uuid: UUID(), cwd: "/focused", title: "focused pane")
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .split(direction: .horizontal, ratio: 0.5, left: .leaf(first), right: .leaf(focused)),
            focusedPaneID: focused.uuid,
            zoomedPaneID: nil
        )
        let other = makeTab()
        let workspace = makeWorkspace(tabs: [other, tab])
        let window = makeWindow(
            workspaces: [workspace],
            selecting: SelectionSnapshot(workspaceID: workspace.id, tabID: other.id)
        )

        let graph = try #require(build(window, registry: PendingHydrationRegistry()))
        let restored = try #require(graph.store.allSessions.first { $0.id == tab.id })

        #expect(restored.title == "focused pane")
        #expect(restored.pwd == "/focused")
    }

    @Test func aUserSetTabNameStillWinsOverTheStoredPaneTitle() throws {
        let leaf = PaneLeafSnapshot(uuid: UUID(), cwd: "/somewhere", title: "shell title")
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: "build",
            tabColor: nil,
            paneTree: .leaf(leaf),
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let workspace = makeWorkspace(tabs: [tab])
        let window = makeWindow(workspaces: [workspace])

        let graph = try #require(build(window, registry: PendingHydrationRegistry()))

        #expect(graph.initialSession.titleOverride == "build")
        #expect(graph.initialSession.title == "shell title")
    }

    @Test func workspaceMetadataSurvives() throws {
        let workspace = makeWorkspace(
            tabs: [makeTab()],
            name: "Rendering",
            defaultDirectory: "/tmp",
            color: .purple,
            isCollapsed: true
        )
        let window = makeWindow(workspaces: [workspace])

        let graph = try #require(build(window, registry: PendingHydrationRegistry()))
        let restored = try #require(graph.store.snapshot.workspaces.first)

        #expect(restored.id == workspace.id)
        #expect(restored.name == "Rendering")
        #expect(restored.color == .purple)
        #expect(restored.isCollapsed)
        #expect(restored.defaultDirectory == "/tmp")
    }

    @Test func emptyWorkspaceListYieldsNoGraph() {
        let window = WindowSnapshot(physicalUUID: UUID(), selection: nil, workspaces: [])
        #expect(build(window, registry: PendingHydrationRegistry()) == nil)
    }

    @Test func danglingSelectionFallsBackWithinTheSnapshot() throws {
        let workspace = makeWorkspace(tabs: [makeTab(), makeTab()])
        let window = makeWindow(
            workspaces: [workspace],
            selecting: SelectionSnapshot(workspaceID: UUID(), tabID: UUID())
        )

        let graph = try #require(build(window, registry: PendingHydrationRegistry()))
        #expect(graph.initialSession.id == workspace.tabs[0].id)
    }

    // MARK: - Working directory resolution

    @Test func liveDirectoryIsPassedThroughExplicitly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = makeWorkspace(tabs: [makeTab()], defaultDirectory: nil)
        let config = TerminalControllerGraphFactory.surfaceConfiguration(
            forLeaf: makeLeaf(cwd: directory.path),
            in: workspace
        )

        #expect(config.workingDirectory == directory.path)
    }

    /// A directory that is gone must be dropped, not replaced with the home
    /// directory: every other tab-creating path in this fork drops it, and a
    /// silent jump to `~` would lie about where the shell landed.
    @Test func deadDirectoryFallsThroughToTheWorkspaceDefault() throws {
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fallback) }

        let workspace = makeWorkspace(tabs: [makeTab()], defaultDirectory: fallback.path)
        let config = TerminalControllerGraphFactory.surfaceConfiguration(
            forLeaf: makeLeaf(cwd: "/nonexistent/\(UUID().uuidString)"),
            in: workspace
        )

        #expect(config.workingDirectory == fallback.path)
    }

    @Test func deadDirectoryAndDeadWorkspaceDefaultLeaveItToTheShell() {
        let workspace = makeWorkspace(
            tabs: [makeTab()],
            defaultDirectory: "/nonexistent/\(UUID().uuidString)"
        )
        let config = TerminalControllerGraphFactory.surfaceConfiguration(
            forLeaf: makeLeaf(cwd: "/nonexistent/\(UUID().uuidString)"),
            in: workspace
        )

        #expect(config.workingDirectory == nil)
    }

    @Test func homeDirectoryIsNeverSubstituted() {
        let workspace = makeWorkspace(tabs: [makeTab()], defaultDirectory: nil)
        let config = TerminalControllerGraphFactory.surfaceConfiguration(
            forLeaf: makeLeaf(cwd: "/nonexistent/\(UUID().uuidString)"),
            in: workspace
        )

        #expect(config.workingDirectory != FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(config.workingDirectory == nil)
    }

    @Test func aFileIsNotAWorkingDirectory() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let workspace = makeWorkspace(tabs: [makeTab()], defaultDirectory: nil)
        let config = TerminalControllerGraphFactory.surfaceConfiguration(
            forLeaf: makeLeaf(cwd: file.path),
            in: workspace
        )

        #expect(config.workingDirectory == nil)
    }

    // MARK: - Registry behavior

    @Test func rekeyMovesAPendingTreeToANewSessionIdentity() {
        let registry = PendingHydrationRegistry()
        let oldID = UUID()
        let newID = UUID()
        registry.store(makeTab(panes: 2), for: oldID)

        registry.rekey(from: oldID, to: newID)

        #expect(!registry.contains(oldID))
        #expect(registry.snapshot(for: newID)?.id == newID)
        #expect(registry.snapshot(for: newID)?.paneTree?.paneCount == 2)
    }

    @Test func takeRemovesTheEntry() {
        let registry = PendingHydrationRegistry()
        let id = UUID()
        registry.store(makeTab(), for: id)

        #expect(registry.take(id) != nil)
        #expect(!registry.contains(id))
        #expect(registry.isEmpty)
    }
}
