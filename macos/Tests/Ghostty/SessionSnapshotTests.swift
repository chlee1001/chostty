import Foundation
import Testing
@testable import Ghostty

/// Pure value work: no `Ghostty.SurfaceView`, no PTY, no controller.
@Suite struct SessionSnapshotTests {
    // MARK: - Fixtures

    /// Exercises every field: both split directions, nesting, nil and non-nil
    /// optionals, a non-default tab color.
    private static func makeFullSnapshot(
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = 4242
    ) -> AppSessionSnapshot {
        let leafA = PaneLeafSnapshot(uuid: UUID(), cwd: "/tmp/a", title: "a")
        let leafB = PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil)
        let leafC = PaneLeafSnapshot(uuid: UUID(), cwd: "/tmp/c", title: "c")

        let nested = PaneTreeSnapshot.split(
            direction: .vertical,
            ratio: 0.25,
            left: .leaf(leafB),
            right: .leaf(leafC)
        )
        let tree = PaneTreeSnapshot.split(
            direction: .horizontal,
            ratio: 0.6,
            left: .leaf(leafA),
            right: nested
        )

        let tab1 = TabSnapshot(
            id: UUID(),
            titleOverride: "server",
            tabColor: "#ff0000",
            paneTree: tree,
            focusedPaneID: leafC.uuid,
            zoomedPaneID: leafA.uuid
        )
        let tab2 = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/", title: "root")),
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        // Representable; the load validator, not the schema, decides whether a
        // paneless tab is acceptable.
        let tab3 = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: nil,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )

        let workspace = WorkspaceSnapshot(
            id: UUID(),
            name: "Workspace 1",
            color: .purple,
            isCollapsed: true,
            defaultDirectory: "/Users/somebody/src",
            tabs: [tab1, tab2, tab3],
            selectedTabID: tab2.id
        )
        let emptyish = WorkspaceSnapshot(
            id: UUID(),
            name: "Workspace 2",
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: [],
            selectedTabID: nil
        )

        let window = WindowSnapshot(
            physicalUUID: UUID(),
            selection: SelectionSnapshot(workspaceID: workspace.id, tabID: tab2.id),
            workspaces: [workspace, emptyish]
        )
        let windowNoSelection = WindowSnapshot(
            physicalUUID: UUID(),
            selection: nil,
            workspaces: []
        )

        return AppSessionSnapshot(
            ownerInstanceID: ownerInstanceID,
            ownerPID: ownerPID,
            windows: [window, windowNoSelection]
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Round trip

    @Test func fullSnapshotSurvivesRoundTrip() throws {
        let original = Self.makeFullSnapshot()

        let data = try Self.encoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)

        #expect(decoded == original)
    }

    @Test func encodingIsByteStableAcrossRepeatedEncodes() throws {
        // The save path skips the write when the bytes match the file on disk,
        // which only works if encoding the same value twice is identical. Hence
        // no timestamp in the body.
        let snapshot = Self.makeFullSnapshot()

        let first = try Self.encoder().encode(snapshot)
        let second = try Self.encoder().encode(snapshot)

        #expect(first == second)
    }

    @Test func distinctSnapshotsEncodeDifferently() throws {
        let a = Self.makeFullSnapshot(ownerPID: 1)
        let b = Self.makeFullSnapshot(ownerInstanceID: a.ownerInstanceID, ownerPID: 2)

        #expect(a != b)
        #expect(try Self.encoder().encode(a) != Self.encoder().encode(b))
    }

    @Test func versionDefaultsToCurrent() {
        let snapshot = Self.makeFullSnapshot()
        #expect(snapshot.version == AppSessionSnapshot.currentVersion)
        #expect(AppSessionSnapshot.currentVersion == 1)
    }

    // MARK: - Pane tree shape

    @Test func splitDirectionRoundTripsAsStableString() throws {
        let data = try Self.encoder().encode([PaneSplitDirection.horizontal, .vertical])
        let json = try #require(String(data: data, encoding: .utf8))

        // Stays readable and independent of `SplitTree.Direction`'s derived
        // encoding.
        #expect(json == #"["horizontal","vertical"]"#)
    }

    @Test func paneTreeRoundTripPreservesShapeRatioAndLeaves() throws {
        let leftLeaf = PaneLeafSnapshot(uuid: UUID(), cwd: "/left", title: "L")
        let rightLeaf = PaneLeafSnapshot(uuid: UUID(), cwd: "/right", title: nil)
        let tree = PaneTreeSnapshot.split(
            direction: .vertical,
            ratio: 0.375,
            left: .leaf(leftLeaf),
            right: .leaf(rightLeaf)
        )

        let decoded = try JSONDecoder().decode(
            PaneTreeSnapshot.self,
            from: try Self.encoder().encode(tree)
        )

        #expect(decoded == tree)
        guard case .split(let direction, let ratio, let left, let right) = decoded else {
            Issue.record("expected a split at the root")
            return
        }
        #expect(direction == .vertical)
        #expect(ratio == 0.375)
        #expect(left == .leaf(leftLeaf))
        #expect(right == .leaf(rightLeaf))
    }

    @Test func paneCountAndDepthDescribeNestedTrees() {
        let leaf = PaneTreeSnapshot.leaf(PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil))
        #expect(leaf.paneCount == 1)
        #expect(leaf.depth == 1)

        let twoWay = PaneTreeSnapshot.split(direction: .horizontal, ratio: 0.5, left: leaf, right: leaf)
        #expect(twoWay.paneCount == 2)
        #expect(twoWay.depth == 2)

        let nested = PaneTreeSnapshot.split(direction: .vertical, ratio: 0.5, left: twoWay, right: leaf)
        #expect(nested.paneCount == 3)
        #expect(nested.depth == 3)
        #expect(nested.leaves.count == 3)
    }

    @Test func workspacePaneCountSumsTabs() {
        let leaf = PaneTreeSnapshot.leaf(PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil))
        let twoWay = PaneTreeSnapshot.split(direction: .horizontal, ratio: 0.5, left: leaf, right: leaf)

        let workspace = WorkspaceSnapshot(
            id: UUID(),
            name: "W",
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: [
                TabSnapshot(id: UUID(), titleOverride: nil, tabColor: nil, paneTree: twoWay, focusedPaneID: nil, zoomedPaneID: nil),
                TabSnapshot(id: UUID(), titleOverride: nil, tabColor: nil, paneTree: leaf, focusedPaneID: nil, zoomedPaneID: nil),
                TabSnapshot(id: UUID(), titleOverride: nil, tabColor: nil, paneTree: nil, focusedPaneID: nil, zoomedPaneID: nil)
            ],
            selectedTabID: nil
        )

        #expect(workspace.paneCount == 3)
    }

    // MARK: - Schema shape

    @Test func snapshotBodyCarriesNoTimestampFrameOrUserTitleFlag() throws {
        let data = try Self.encoder().encode(Self.makeFullSnapshot())
        let json = try #require(String(data: data, encoding: .utf8))

        // Each was deliberately removed; reintroducing one breaks either
        // idle-write-zero or an existing authority.
        #expect(!json.contains("createdAt"))
        #expect(!json.contains("\"frame\""))
        #expect(!json.contains("isFullscreen"))
        #expect(!json.contains("isUserSetTitle"))
    }

    @Test func tabColorRawValuesArePositionalAndStable() throws {
        // Int-raw, so the values are positional. Pinned here so an accidental
        // case insertion fails instead of repainting every stored workspace.
        #expect(TerminalTabColor.none.rawValue == 0)
        #expect(TerminalTabColor.blue.rawValue == 1)
        #expect(TerminalTabColor.purple.rawValue == 2)

        let decoded = try JSONDecoder().decode(
            TerminalTabColor.self,
            from: try Self.encoder().encode(TerminalTabColor.purple)
        )
        #expect(decoded == .purple)
    }
}
