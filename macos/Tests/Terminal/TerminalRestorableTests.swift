import Testing
import AppKit
@testable import Ghostty

@Suite
struct TerminalRestorableTests {
    @Test
    func areYouForgettingToAddMigrationTests() {
        // v8: Chostty nested workspace hierarchy. Legacy v5-v7 state is rejected.
        #expect(TerminalRestorableState.version == 8)
        #expect(TerminalRestorableState.minimumVersion == 8)

        #expect(QuickTerminalRestorableState.version == 1)
        #expect(QuickTerminalRestorableState.minimumVersion == 1)
    }

    @MainActor
    @Test func quickTerminalRestorableFromV1() throws {
        /* v1
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let state = DummyQuickTerminalRestorableState(
            focusedSurface: "123",
            surfaceTree: tree.0,
            screenStateEntries: [:],
        )
        let data = try archive(CodableBridge(state), className: "CodableBridge<QuickTerminal>")
        print(data.base64EncodedString())
        print(tree.1.id)
        print(tree.2.id)
        */

        let decoded: CodableBridge<DummyQuickTerminalRestorableState> = try unarchive(v1QTData, className: "CodableBridge<QuickTerminal>")
        let state = decoded.value.internalState

        #expect(state.focusedSurface == "123")
        #expect(state.screenStateEntries.isEmpty)
        #expect(state.surfaceTree.contains(where: { $0.id.uuidString == "2F2F2D93-944C-474A-83BA-4DC1868C3EB9" }))
        #expect(state.surfaceTree.contains(where: { $0.id.uuidString == "994C673F-B4C5-49EE-B044-65006652636D" }))
    }

    // MARK: - v8 nested hierarchy
    //
    // v8 is the Chostty Workspace → Virtual Tab → Pane format. `workspaces` is
    // the single source of truth; the legacy flat `surfaceTree` field must stay
    // EMPTY on encode.
    //
    // That last point is load-bearing rather than cosmetic: a persisted
    // `SplitTree<Ghostty.SurfaceView>` does not decode passively — each
    // `SurfaceView` decoder constructs a live surface and spawns a PTY, reusing
    // the persisted UUID. Encoding the presented tree both flat and inside
    // `workspaces` would therefore restore every presented surface twice:
    // duplicate processes plus two live views sharing one UUID, which is the
    // key the owner registry and the store's surface index are built on.

    @Test func v8EncodesHierarchyAndLeavesFlatTreeEmpty() throws {
        let tabID = UUID()
        let wsID = UUID()
        let surfaceID = UUID()

        let tab = TerminalRestorableState.TabState<MockView>(
            id: tabID,
            surfaceTree: .init(view: MockView(id: surfaceID)),
            focusedSurfaceID: surfaceID.uuidString,
            title: "build",
            pwd: "/tmp/work",
            tabColor: nil,
            titleOverride: nil,
            isRestorable: true
        )
        let ws = TerminalRestorableState.WorkspaceState<MockView>(
            id: wsID,
            name: "Workspace 1",
            tabs: [tab],
            selectedTabID: tabID
        )
        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: surfaceID.uuidString,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil,
            physicalID: UUID(),
            workspaces: [ws],
            selectedWorkspaceID: wsID,
            selectedTabID: tabID
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self, from: data)

        // The hierarchy round-trips.
        #expect(decoded.workspaces?.count == 1)
        #expect(decoded.workspaces?[0].id == wsID)
        #expect(decoded.workspaces?[0].tabs.count == 1)
        #expect(decoded.workspaces?[0].tabs[0].id == tabID)
        #expect(decoded.workspaces?[0].tabs[0].title == "build")
        #expect(decoded.workspaces?[0].tabs[0].pwd == "/tmp/work")
        #expect(decoded.selectedWorkspaceID == wsID)
        #expect(decoded.selectedTabID == tabID)

        // The flat tree carries no surfaces, so nothing is materialized twice.
        #expect(decoded.surfaceTree.isEmpty)
    }

    @Test func v8RoundTripsMultipleWorkspacesAndTabsInOrder() throws {
        func makeTab(_ title: String) -> (UUID, TerminalRestorableState.TabState<MockView>) {
            let id = UUID()
            return (id, .init(
                id: id,
                surfaceTree: .init(view: MockView(id: UUID())),
                focusedSurfaceID: nil,
                title: title,
                pwd: nil,
                tabColor: nil,
                titleOverride: nil,
                isRestorable: true
            ))
        }

        let (a1, t1) = makeTab("a1")
        let (a2, t2) = makeTab("a2")
        let (b1, t3) = makeTab("b1")
        let wsA = UUID(), wsB = UUID()

        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: nil,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil,
            physicalID: UUID(),
            workspaces: [
                .init(id: wsA, name: "A", tabs: [t1, t2], selectedTabID: a2),
                .init(id: wsB, name: "B", tabs: [t3], selectedTabID: b1),
            ],
            selectedWorkspaceID: wsB,
            selectedTabID: b1
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self, from: data)

        #expect(decoded.workspaces?.count == 2)
        #expect(decoded.workspaces?.map(\.name) == ["A", "B"])
        // Tab order within a workspace is preserved.
        #expect(decoded.workspaces?[0].tabs.map(\.id) == [a1, a2])
        #expect(decoded.workspaces?[0].selectedTabID == a2)
        #expect(decoded.workspaces?[1].tabs.map(\.id) == [b1])
        // Cross-workspace selection is preserved.
        #expect(decoded.selectedWorkspaceID == wsB)
        #expect(decoded.selectedTabID == b1)
        #expect(decoded.surfaceTree.isEmpty)
    }
    @Test func v8RoundTripsDefaultDirectory() throws {
        let tabID = UUID()
        let wsID = UUID()

        let tab = TerminalRestorableState.TabState<MockView>(
            id: tabID,
            surfaceTree: .init(),
            focusedSurfaceID: nil,
            title: "t",
            pwd: nil,
            tabColor: nil,
            titleOverride: nil,
            isRestorable: true
        )
        let ws = TerminalRestorableState.WorkspaceState<MockView>(
            id: wsID,
            name: "Workspace 1",
            tabs: [tab],
            selectedTabID: tabID,
            color: .teal,
            isCollapsed: true,
            defaultDirectory: "/tmp/x"
        )
        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: nil,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil,
            physicalID: UUID(),
            workspaces: [ws],
            selectedWorkspaceID: wsID,
            selectedTabID: tabID
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self, from: data)

        #expect(decoded.workspaces?[0].defaultDirectory == "/tmp/x")
        #expect(decoded.workspaces?[0].color == .teal)
        #expect(decoded.workspaces?[0].isCollapsed == true)
    }

    @Test func v8DecodesWhenDefaultDirectoryIsAbsentFromThePayload() throws {
        // A payload written before `defaultDirectory` existed (or one that
        // simply omits the key) must still decode, yielding nil rather than
        // failing — the same contract `color`/`isCollapsed` already have.
        struct LegacyWorkspaceState: Encodable {
            let id: UUID
            let name: String
            let tabs: [TerminalRestorableState.TabState<MockView>]
            let selectedTabID: UUID?
        }

        let tabID = UUID()
        let wsID = UUID()
        let legacyWorkspace = LegacyWorkspaceState(
            id: wsID,
            name: "Workspace 1",
            tabs: [
                TerminalRestorableState.TabState<MockView>(
                    id: tabID,
                    surfaceTree: .init(),
                    focusedSurfaceID: nil,
                    title: "t",
                    pwd: nil,
                    tabColor: nil,
                    titleOverride: nil,
                    isRestorable: true
                )
            ],
            selectedTabID: tabID
        )

        let data = try JSONEncoder().encode(legacyWorkspace)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.WorkspaceState<MockView>.self, from: data)

        #expect(decoded.defaultDirectory == nil)
        #expect(decoded.color == nil)
        #expect(decoded.isCollapsed == nil)
    }

    // MARK: - v8 hierarchy validation
    //
    // `makeRestoredV8` must reject a structurally invalid hierarchy rather than
    // materialize a partial one. Duplicate surface IDs are the dangerous case:
    // `Ghostty.SurfaceView`'s decoder spawns a live PTY, so a repeated surface
    // UUID would produce two live views sharing one identity — which is the key
    // both the owner registry and the store's surface index are built on.

    @Test func v8RejectsDuplicateWorkspaceIDs() {
        let dupID = UUID()
        let ws1 = TerminalRestorableState.WorkspaceState<Ghostty.SurfaceView>(
            id: dupID, name: "A", tabs: [makeEmptyTab()], selectedTabID: nil)
        let ws2 = TerminalRestorableState.WorkspaceState<Ghostty.SurfaceView>(
            id: dupID, name: "B", tabs: [makeEmptyTab()], selectedTabID: nil)

        let graph = TerminalControllerGraphFactory.makeRestoredV8(
            workspaces: [ws1, ws2], selectedWorkspaceID: nil, selectedTabID: nil)
        #expect(graph == nil)
    }

    @Test func v8RejectsDuplicateTabIDs() {
        let dupTab = UUID()
        let t1 = makeEmptyTab(id: dupTab)
        let t2 = makeEmptyTab(id: dupTab)
        let ws = TerminalRestorableState.WorkspaceState<Ghostty.SurfaceView>(
            id: UUID(), name: "A", tabs: [t1, t2], selectedTabID: nil)

        let graph = TerminalControllerGraphFactory.makeRestoredV8(
            workspaces: [ws], selectedWorkspaceID: nil, selectedTabID: nil)
        #expect(graph == nil)
    }

    @Test func v8RejectsEmptyWorkspaceList() {
        let graph = TerminalControllerGraphFactory.makeRestoredV8(
            workspaces: [], selectedWorkspaceID: nil, selectedTabID: nil)
        #expect(graph == nil)
    }

    @Test func v8RejectsWorkspaceWithNoTabs() {
        let ws = TerminalRestorableState.WorkspaceState<Ghostty.SurfaceView>(
            id: UUID(), name: "A", tabs: [], selectedTabID: nil)
        let graph = TerminalControllerGraphFactory.makeRestoredV8(
            workspaces: [ws], selectedWorkspaceID: nil, selectedTabID: nil)
        #expect(graph == nil)
    }

    private func makeEmptyTab(
        id: UUID = UUID()
    ) -> TerminalRestorableState.TabState<Ghostty.SurfaceView> {
        .init(
            id: id,
            surfaceTree: .init(),
            focusedSurfaceID: nil,
            title: "t",
            pwd: nil,
            tabColor: nil,
            titleOverride: nil,
            isRestorable: true
        )
    }

    @Test func v8DecodesWhenHierarchyIsAbsent() throws {
        // A payload without `workspaces` must still decode; the restore path
        // treats a nil/invalid hierarchy as "start fresh" rather than crashing.
        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: nil,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self, from: data)

        #expect(decoded.workspaces == nil)
        #expect(decoded.selectedWorkspaceID == nil)
        #expect(decoded.physicalID == nil)
    }
}

private extension TerminalRestorableTests {
    func archive<T: NSObject & NSSecureCoding>(_ obj: T, className: String?) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        defer { archiver.finishEncoding() }
        if let className {
            archiver.setClassName(className, for: T.self)
        }
        archiver.encode(obj, forKey: NSKeyedArchiveRootObjectKey)
        return archiver.encodedData
    }

    func unarchive<T: NSObject & NSSecureCoding>(_ data: Data, className: String?, as: T.Type = T.self) throws -> T {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding()}
        if let className {
            unarchiver.setClass(T.self, forClassName: className)
        }
        unarchiver.requiresSecureCoding = true
        let result = unarchiver.decodeObject(of: T.self, forKey: NSKeyedArchiveRootObjectKey)
        return try #require(result)
    }
}

// MARK: - Dummy States

@MainActor
struct DummyQuickTerminalRestorableState: TerminalRestorable {
    static var version: Int = QuickTerminalRestorableState.version

    static var minimumVersion: Int = QuickTerminalRestorableState.minimumVersion

    init(copy other: DummyQuickTerminalRestorableState) {
        internalState = other.internalState
    }

    let internalState: QuickTerminalRestorableState.InternalState<MockView>

    init(_ internalState: QuickTerminalRestorableState.InternalState<MockView>) {
        self.internalState = internalState
    }

    init(from decoder: any Decoder) throws {
        self.internalState = try QuickTerminalRestorableState.InternalState<MockView>(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

// MARK: - QuickTerminal V1 (1.3.0)

private let v1QTData = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA6hicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECALDBkaGxwfJicvMDEyODlFRkdISU9QVldYXF1jaWpwcVUkbnVsbNMNDg8QFBhXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6MREhOAAoADgASjFRYXgAWAB4AIgBhfEBJzY3JlZW5TdGF0ZUVudHJpZXNeZm9jdXNlZFN1cmZhY2Vbc3VyZmFjZVRyZWXSDg8dHqCABtIgISIjWiRjbGFzc25hbWVYJGNsYXNzZXNeTlNNdXRhYmxlQXJyYXmjIiQlV05TQXJyYXlYTlNPYmplY3RTMTIz0w0ODygrGKIpKoAJgAqiLC2AC4AMgBhXdmVyc2lvblRyb290EAHTDQ4PMzUYoTSADaE2gA6AGFVzcGxpdNMNDg86PxikOzw9PoAPgBCAEYASpEBBQkOAE4AZgBqAHYAYVXJpZ2h0VXJhdGlvVGxlZnRZZGlyZWN0aW9u0w0OD0pMGKFLgBShTYAVgBhUdmlld9MNDg9RUxihUoAWoVSAF4AYUmlkXxAkOTk0QzY3M0YtQjRDNS00OUVFLUIwNDQtNjUwMDY2NTI2MzZE0iAhWVpfEBNOU011dGFibGVEaWN0aW9uYXJ5o1lbJVxOU0RpY3Rpb25hcnkjP+AAAAAAAADTDQ4PXmAYoUuAFKFhgBuAGNMNDg9kZhihUoAWoWeAHIAYXxAkMkYyRjJEOTMtOTQ0Qy00NzRBLTgzQkEtNERDMTg2OEMzRUI50w0OD2ttGKFsgB6hboAfgBhaaG9yaXpvbnRhbNMNDg9ycxigoIAYAAgAEQAaACQAKQAyADcASQBMAFIAVAB3AH0AhACMAJcAngCiAKQApgCoAKwArgCwALIAtADJANgA5ADpAOoA7ADxAPwBBQEUARgBIAEpAS0BNAE3ATkBOwE+AUABQgFEAUwBUQFTAVoBXAFeAWABYgFkAWoBcQF2AXgBegF8AX4BgwGFAYcBiQGLAY0BkwGZAZ4BqAGvAbEBswG1AbcBuQG+AcUBxwHJAcsBzQHPAdIB+QH+AhQCGAIlAi4CNQI3AjkCOwI9Aj8CRgJIAkoCTAJOAlACdwJ+AoACggKEAoYCiAKTApoCmwKcAAAAAAAAAgEAAAAAAAAAdQAAAAAAAAAAAAAAAAAAAp7RExRaJGNsYXNzbmFtZV8QHENvZGFibGVCcmlkZ2U8UXVpY2tUZXJtaW5hbD4ACAARABoAJAApADIANwBJAEwAUQBTAFgAXgBjAGgAbwBxAHMEHwQiBC0AAAAAAAACAQAAAAAAAAAVAAAAAAAAAAAAAAAAAAAETA==
    """)!

