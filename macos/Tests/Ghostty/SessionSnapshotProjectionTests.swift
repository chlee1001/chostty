import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Every surface is built with `spawnsSurface: false`, so no PTY, renderer
/// thread or IO thread is created. The projection layer only reads view
/// properties and rebuilds tree shape, which that mode still supports.
@MainActor
@Suite struct SessionSnapshotProjectionTests {
    // MARK: - Helpers

    private enum TestError: Error {
        case timedOut
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `nil` when the shared headless app is unavailable, so a test skips
    /// rather than crashes.
    private func makeView(id: UUID = UUID(), pwd: String? = nil, title: String? = nil) -> Ghostty.SurfaceView? {
        guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
        let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: id, spawnsSurface: false)
        view.pwd = pwd
        if let title { view.setTitle(title) }
        return view
    }

    /// Mirrors the production shape but creates nothing live.
    private func testFactory() -> SessionSnapshotProjection.SurfaceFactory {
        { leaf in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: leaf.uuid, spawnsSurface: false)
            view.pwd = leaf.cwd
            return view
        }
    }

    private func split(
        _ direction: SplitTree<Ghostty.SurfaceView>.Direction,
        ratio: Double,
        _ left: SplitTree<Ghostty.SurfaceView>.Node,
        _ right: SplitTree<Ghostty.SurfaceView>.Node
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        .split(.init(direction: direction, ratio: ratio, left: left, right: right))
    }

    // MARK: - Live → value

    @Test func emptyTreeProjectsToNil() {
        #expect(SessionSnapshotProjection.paneTree(from: SplitTree<Ghostty.SurfaceView>()) == nil)
    }

    @Test func singleLeafProjectsUUIDAndCwd() throws {
        let id = UUID()
        let view = try #require(makeView(id: id, pwd: "/tmp/one"))
        let tree = SplitTree(view: view)

        let snapshot = try #require(SessionSnapshotProjection.paneTree(from: tree))
        guard case .leaf(let leaf) = snapshot else {
            Issue.record("expected a leaf")
            return
        }
        #expect(leaf.uuid == id)
        #expect(leaf.cwd == "/tmp/one")
    }

    @Test func emptyTitleProjectsAsNilRatherThanEmptyString() throws {
        let view = try #require(makeView(pwd: "/tmp"))
        // A freshly built surface has no title yet.
        let leaf = SessionSnapshotProjection.leaf(from: view)
        #expect(leaf.title == nil)
    }

    @Test(arguments: [
        (nil, nil), ("", ""), ("short", "short"), ("é👨‍👩‍👧‍👦", "é👨‍👩‍👧‍👦"),
        (
            String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength),
            String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength)
        ),
        (
            String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength + 1),
            String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength)
        ),
        (
            String(repeating: "é", count: SessionSnapshotValidator.Limits.stringLength / 2),
            String(repeating: "é", count: SessionSnapshotValidator.Limits.stringLength / 2)
        ),
        (
            String(repeating: "é", count: SessionSnapshotValidator.Limits.stringLength / 2 + 1),
            String(repeating: "é", count: SessionSnapshotValidator.Limits.stringLength / 2)
        ),
        (
            String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength - 1) + "👨‍👩‍👧‍👦z",
            String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength - 1)
        ),
        (
            String(repeating: "e\u{301}", count: SessionSnapshotValidator.Limits.stringLength),
            String(repeating: "e\u{301}", count: SessionSnapshotValidator.Limits.stringLength / 3)
        ),
        (
            "safe e" + String(repeating: "\u{301}", count: SessionSnapshotValidator.Limits.stringLength) + "z",
            "safe "
        )
    ] as [(String?, String?)])
    func liveMetadataIsBoundedWithoutLosingOptionalOrEmptyValues(
        value: String?, expected: String?
    ) async throws {
        let view = try #require(makeView(pwd: value))
        if let value, !value.isEmpty {
            view.setTitle(value)
            try await waitUntil { view.title == value }
        }
        let session = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: view))
        session.titleOverride = value
        session.tabColor = value
        var workspace = WorkspaceSession(
            id: UUID(), name: value ?? "", tabs: [session], selectedTabID: session.id
        )
        workspace.defaultDirectory = value

        let snapshot = SessionSnapshotProjection.workspace(from: workspace)
        let tab = try #require(snapshot.tabs.first)
        let leaf = try #require(tab.paneTree?.leaves.first)
        #expect(leaf.cwd == expected)
        #expect(leaf.title == (value == "" ? nil : expected))
        #expect(tab.titleOverride == expected)
        #expect(tab.tabColor == expected)
        #expect(snapshot.name == (expected ?? ""))
        #expect(snapshot.defaultDirectory == expected)
        // Bounding must not mutate the live model.
        #expect(view.pwd == value)
        #expect(session.titleOverride == value)
        #expect(workspace.defaultDirectory == value)

        let appSnapshot = AppSessionSnapshot(
            ownerInstanceID: UUID(), ownerPID: 1,
            windows: [WindowSnapshot(physicalUUID: UUID(), selection: nil, workspaces: [snapshot])]
        )
        guard case .success = SessionSnapshotValidator.validate(appSnapshot) else {
            Issue.record("bounded live metadata must pass the shared validator")
            return
        }
    }

    @Test(arguments: [SplitTree<Ghostty.SurfaceView>.Direction.horizontal, .vertical])
    func twoWaySplitProjectsDirectionRatioAndBothLeaves(
        direction: SplitTree<Ghostty.SurfaceView>.Direction
    ) throws {
        let leftID = UUID()
        let rightID = UUID()
        let left = try #require(makeView(id: leftID, pwd: "/left"))
        let right = try #require(makeView(id: rightID, pwd: "/right"))
        let tree = SplitTree<Ghostty.SurfaceView>(
            root: split(direction, ratio: 0.4, .leaf(view: left), .leaf(view: right)),
            zoomed: nil
        )

        let snapshot = try #require(SessionSnapshotProjection.paneTree(from: tree))
        guard case .split(let projected, let ratio, let leftSnapshot, let rightSnapshot) = snapshot else {
            Issue.record("expected a split")
            return
        }
        #expect(projected == SessionSnapshotProjection.direction(from: direction))
        #expect(ratio == 0.4)
        #expect(leftSnapshot == .leaf(PaneLeafSnapshot(uuid: leftID, cwd: "/left", title: nil)))
        #expect(rightSnapshot == .leaf(PaneLeafSnapshot(uuid: rightID, cwd: "/right", title: nil)))
    }

    @Test func zoomedLeafProjectsItsUUID() throws {
        let zoomedID = UUID()
        let left = try #require(makeView(id: zoomedID))
        let right = try #require(makeView())
        let leftNode = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: left)
        let tree = SplitTree<Ghostty.SurfaceView>(
            root: split(.horizontal, ratio: 0.5, leftNode, .leaf(view: right)),
            zoomed: leftNode
        )

        #expect(SessionSnapshotProjection.zoomedPaneID(in: tree) == zoomedID)
    }

    @Test func unzoomedTreeProjectsNoZoomedPane() throws {
        let view = try #require(makeView())
        #expect(SessionSnapshotProjection.zoomedPaneID(in: SplitTree(view: view)) == nil)
    }

    @Test func sessionProjectsIdentityOverridesAndTree() throws {
        let paneID = UUID()
        let view = try #require(makeView(id: paneID, pwd: "/work"))
        let session = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: view))
        session.titleOverride = "server"
        session.tabColor = "#00ff00"
        session.focusedSurfaceID = paneID

        let tab = SessionSnapshotProjection.tab(from: session)

        #expect(tab.id == session.id)
        #expect(tab.titleOverride == "server")
        #expect(tab.tabColor == "#00ff00")
        #expect(tab.focusedPaneID == paneID)
        #expect(tab.paneTree?.paneCount == 1)
        #expect(tab.zoomedPaneID == nil)
    }

    @Test func workspaceProjectsMetadataAndTabOrder() throws {
        let a = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: try #require(makeView())))
        let b = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: try #require(makeView())))
        var workspace = WorkspaceSession(id: UUID(), name: "Workspace 7", tabs: [a, b], selectedTabID: b.id)
        workspace.color = .green
        workspace.isCollapsed = true
        workspace.defaultDirectory = "/srv"

        let snapshot = SessionSnapshotProjection.workspace(from: workspace)

        #expect(snapshot.id == workspace.id)
        #expect(snapshot.name == "Workspace 7")
        #expect(snapshot.color == .green)
        #expect(snapshot.isCollapsed)
        #expect(snapshot.defaultDirectory == "/srv")
        #expect(snapshot.tabs.map(\.id) == [a.id, b.id])
        #expect(snapshot.selectedTabID == b.id)
    }

    /// An unhydrated tab keeps its stored tree while live sidebar metadata wins.
    @Test func pendingTabKeepsStoredTreeAndCurrentMetadata() throws {
        let hydrated = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: try #require(makeView())))
        let pending = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())

        let storedTree = PaneTreeSnapshot.split(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/a", title: nil)),
            right: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/b", title: nil))
        )
        let storedTab = TabSnapshot(
            id: pending.id,
            titleOverride: "kept",
            tabColor: nil,
            paneTree: storedTree,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        pending.titleOverride = "renamed"
        pending.tabColor = "2"

        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [hydrated, pending],
            selectedTabID: hydrated.id
        )

        let snapshot = SessionSnapshotProjection.workspace(
            from: workspace,
            pendingTabs: [pending.id: storedTab]
        )

        #expect(snapshot.tabs[0].paneTree?.paneCount == 1)
        #expect(snapshot.tabs[1].paneTree?.paneCount == 2)
        #expect(snapshot.tabs[1].paneTree == storedTree)
        #expect(snapshot.tabs[1].titleOverride == "renamed")
        #expect(snapshot.tabs[1].tabColor == "2")
    }

    // MARK: - Value → live

    @Test func nilSnapshotRebuildsEmptyTree() {
        let tree = SessionSnapshotProjection.surfaceTree(from: nil, makeSurface: testFactory())
        #expect(tree.isEmpty)
    }

    @Test(arguments: [PaneSplitDirection.horizontal, .vertical])
    func roundTripPreservesShapeDirectionRatioAndCwd(direction: PaneSplitDirection) throws {
        let leftID = UUID()
        let rightID = UUID()
        let original = PaneTreeSnapshot.split(
            direction: direction,
            ratio: 0.3,
            left: .leaf(PaneLeafSnapshot(uuid: leftID, cwd: "/left", title: nil)),
            right: .leaf(PaneLeafSnapshot(uuid: rightID, cwd: "/right", title: nil))
        )

        let tree = SessionSnapshotProjection.surfaceTree(from: original, makeSurface: testFactory())
        let reprojected = try #require(SessionSnapshotProjection.paneTree(from: tree))

        #expect(reprojected == original)
    }

    @Test func roundTripPreservesNestedShape() throws {
        let original = PaneTreeSnapshot.split(
            direction: .horizontal,
            ratio: 0.6,
            left: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/a", title: nil)),
            right: .split(
                direction: .vertical,
                ratio: 0.25,
                left: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/b", title: nil)),
                right: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/c", title: nil))
            )
        )

        let tree = SessionSnapshotProjection.surfaceTree(from: original, makeSurface: testFactory())
        let reprojected = try #require(SessionSnapshotProjection.paneTree(from: tree))

        #expect(reprojected == original)
        #expect(reprojected.paneCount == 3)
        #expect(reprojected.depth == 3)
    }

    @Test func zoomRoundTripsThroughLeafUUID() throws {
        let zoomedID = UUID()
        let original = PaneTreeSnapshot.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(PaneLeafSnapshot(uuid: zoomedID, cwd: nil, title: nil)),
            right: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil))
        )

        let tree = SessionSnapshotProjection.surfaceTree(
            from: original,
            zoomedPaneID: zoomedID,
            makeSurface: testFactory()
        )

        #expect(SessionSnapshotProjection.zoomedPaneID(in: tree) == zoomedID)
    }

    /// A leaf the factory declines is dropped and its split collapses, rather
    /// than failing the whole tab.
    @Test func declinedLeafCollapsesItsSplit() throws {
        let keptID = UUID()
        let droppedID = UUID()
        let original = PaneTreeSnapshot.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(PaneLeafSnapshot(uuid: droppedID, cwd: nil, title: nil)),
            right: .leaf(PaneLeafSnapshot(uuid: keptID, cwd: "/kept", title: nil))
        )

        let base = testFactory()
        let tree = SessionSnapshotProjection.surfaceTree(from: original) { leaf in
            leaf.uuid == droppedID ? nil : base(leaf)
        }

        let reprojected = try #require(SessionSnapshotProjection.paneTree(from: tree))
        #expect(reprojected == .leaf(PaneLeafSnapshot(uuid: keptID, cwd: "/kept", title: nil)))
    }

    @Test func allLeavesDeclinedYieldsEmptyTree() {
        let original = PaneTreeSnapshot.split(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil)),
            right: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil))
        )

        let tree = SessionSnapshotProjection.surfaceTree(from: original) { _ in nil }
        #expect(tree.isEmpty)
    }

    @Test func directionMappingIsSymmetric() {
        for value in [PaneSplitDirection.horizontal, .vertical] {
            let live = SessionSnapshotProjection.direction(from: value)
            #expect(SessionSnapshotProjection.direction(from: live) == value)
        }
    }
}
