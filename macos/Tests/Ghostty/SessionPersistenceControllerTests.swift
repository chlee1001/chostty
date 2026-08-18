import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Save-trigger tests, against harness-built controllers whose surfaces are
/// `spawnsSurface: false` and a repository in a temporary directory.
///
/// The controller under test always gets an explicit `controllersProvider`,
/// never `TerminalController.all`: the harness leaves every controller it built
/// in `NSApp.windows` for the life of the test host, so a global lookup would
/// make results depend on which suites ran first.
@MainActor
@Suite struct SessionPersistenceControllerTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-persist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSurface(pwd: String? = nil) -> Ghostty.SurfaceView? {
        guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
        let view = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        view.pwd = pwd
        return view
    }

    private func makeSession(pwd: String? = nil) throws -> TerminalSessionState {
        let view = try #require(makeSurface(pwd: pwd))
        let session = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: view))
        session.focusedSurfaceID = view.id
        return session
    }

    private func makeController(
        workspaceName: String = "Workspace 1",
        tabCount: Int = 1
    ) throws -> TerminalController {
        let tabs = try (0..<tabCount).map { _ in try makeSession(pwd: "/tmp") }
        var workspace = WorkspaceSession(
            id: UUID(),
            name: workspaceName,
            tabs: tabs,
            selectedTabID: tabs.first?.id
        )
        workspace.color = .none
        let selection = Selection(workspaceID: workspace.id, tabID: try #require(tabs.first).id)
        return try #require(TerminalControllerTestHarness.make(workspaces: [workspace], selection: selection))
    }

    /// Open regardless of the surrounding test environment.
    private func openGate() -> SessionPersistenceGate {
        SessionPersistenceGate(environment: [:], arguments: [], configEnabled: true)
    }

    private func makePersistence(
        directory: URL,
        registry: PendingHydrationRegistry? = nil,
        controllers: @escaping () -> [TerminalController]
    ) -> SessionPersistenceController {
        SessionPersistenceController(
            repository: SessionSnapshotRepository(directory: directory),
            gate: openGate(),
            registry: registry ?? PendingHydrationRegistry(),
            ownerInstanceID: UUID(),
            ownerPID: 4242,
            controllersProvider: controllers
        )
    }

    private func decode(_ repository: SessionSnapshotRepository) throws -> AppSessionSnapshot {
        let data = try Data(contentsOf: repository.primaryURL)
        return try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    private func paneCount(_ snapshot: AppSessionSnapshot) -> Int {
        snapshot.windows
            .flatMap(\.workspaces)
            .flatMap(\.tabs)
            .reduce(0) { $0 + ($1.paneTree?.paneCount ?? 0) }
    }

    // MARK: - (1) Idle: no extra write, deterministic window order

    @Test func repeatedCallsWithoutChangesWriteOnceAndKeepWindowOrderStable() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let first = try makeController(workspaceName: "One")
        let second = try makeController(workspaceName: "Two")
        let persistence = makePersistence(directory: directory) { [first, second] }

        // The first tick always projects: this process owns the file now.
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        let baselineDate = try modificationDate(repository.primaryURL)
        let baseline = try decode(repository)
        #expect(baseline.windows.count == 2)

        // Filesystem timestamps are coarse; long enough that a second write
        // would be observable.
        Thread.sleep(forTimeInterval: 1.1)

        #expect(!persistence.persistIfNeeded())
        #expect(!persistence.persistIfNeeded())
        persistence.flush()

        #expect(try modificationDate(repository.primaryURL) == baselineDate)

        // Ordered by physicalUUID, not by NSApp.windows order.
        let expectedOrder = [first.physicalUUID, second.physicalUUID]
            .sorted { $0.uuidString < $1.uuidString }
        #expect(baseline.windows.map(\.physicalUUID) == expectedOrder)
    }

    // MARK: - (2) Structural commit is reflected

    @Test func renamingAWorkspaceIsWrittenOnTheNextCall() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController(workspaceName: "Before")
        let persistence = makePersistence(directory: directory) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(try decode(repository).windows[0].workspaces[0].name == "Before")

        let store = controller.workspaceStore
        let workspaceID = store.snapshot.workspaces[0].id
        store.renameWorkspace(workspaceID, to: "After")

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(try decode(repository).windows[0].workspaces[0].name == "After")
    }

    // MARK: - (3) Pending tabs are republished, never erased

    @Test func pendingTabsKeepTheirPaneCountAcrossRepeatedSaves() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)

        // Live trees empty, exactly as boot leaves them.
        let hydrated = try makeSession(pwd: "/live")
        let pendingA = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let pendingB = TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [hydrated, pendingA, pendingB],
            selectedTabID: hydrated.id
        )
        let selection = Selection(workspaceID: workspace.id, tabID: hydrated.id)
        let controller = try #require(
            TerminalControllerTestHarness.make(workspaces: [workspace], selection: selection)
        )

        let registry = PendingHydrationRegistry()
        for session in [pendingA, pendingB] {
            registry.store(
                TabSnapshot(
                    id: session.id,
                    titleOverride: nil,
                    tabColor: nil,
                    paneTree: .split(
                        direction: .horizontal,
                        ratio: 0.5,
                        left: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/a", title: nil)),
                        right: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/b", title: nil))
                    ),
                    focusedPaneID: nil,
                    zoomedPaneID: nil
                ),
                for: session.id
            )
        }

        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }

        // 1 live pane + 2 pending tabs of 2 panes each.
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(paneCount(try decode(repository)) == 5)

        // The second call must not overwrite them with their empty live trees.
        _ = persistence.persistIfNeeded()
        persistence.flush()
        #expect(paneCount(try decode(repository)) == 5)
    }

    // MARK: - (4)(5) Metadata changes move the counter; one write per tick

    @Test func renamingATabUpdatesDiskAndCoalescesWithinOneTick() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(try decode(repository).windows[0].workspaces[0].tabs[0].titleOverride == nil)

        let store = controller.workspaceStore
        let tabID = store.snapshot.workspaces[0].tabs[0].id
        // Renaming never reaches `commit`, so this only shows up on disk
        // because `renameTab` bumps the metadata generation.
        store.renameTab(tabID, to: "server")

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        let afterRename = try modificationDate(repository.primaryURL)
        #expect(try decode(repository).windows[0].workspaces[0].tabs[0].titleOverride == "server")

        // Filesystem timestamps are coarse; long enough that a second write
        // would be observable.
        Thread.sleep(forTimeInterval: 1.1)

        // Nothing changed since, so no second write.
        #expect(!persistence.persistIfNeeded())
        persistence.flush()
        #expect(try modificationDate(repository.primaryURL) == afterRename)
    }

    @Test func settingATabColorIsWritten() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let store = controller.workspaceStore
        store.setTabColor(store.snapshot.workspaces[0].tabs[0].id, to: .green)

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(
            try decode(repository).windows[0].workspaces[0].tabs[0].tabColor
                == String(TerminalTabColor.green.rawValue)
        )
    }

    // MARK: - (6) Splits are captured even though they bypass commit

    @Test func splittingAPaneIsCapturedByTheNextSave() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(paneCount(try decode(repository)) == 1)

        // A split assigns `surfaceTree` directly and never routes through
        // `commit`, so `mountGeneration` does not move. Only the bump inside
        // `surfaceTreeDidChange` makes this observable.
        let existing = try #require(controller.surfaceTree.root)
        let added = try #require(makeSurface(pwd: "/added"))
        controller.surfaceTree = SplitTree<Ghostty.SurfaceView>(
            root: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: existing,
                right: .leaf(view: added)
            )),
            zoomed: nil
        )

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(paneCount(try decode(repository)) == 2)
    }

    // MARK: - Non-focused pane directories

    @Test func backgroundPaneDirectoryChangeIsSavedAndDoesNotHijackSessionPwd() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        let focused = try #require(controller.surfaceTree.first)
        let background = try #require(makeSurface(pwd: "/background"))
        controller.surfaceTree = SplitTree<Ghostty.SurfaceView>(
            root: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(view: focused),
                right: .leaf(view: background)
            )),
            zoomed: nil
        )

        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let presentedID = try #require(controller.presentedSessionID)
        let session = try #require(controller.workspaceStore.session(forTabID: presentedID))
        let sessionPwdBefore = session.pwd
        let focusedCwdBefore = try #require(
            try decode(repository).windows[0].workspaces[0].tabs[0].paneTree?
                .leaves.first(where: { $0.uuid == focused.id })?.cwd
        )

        // Only the background pane moves.
        background.pwd = "/background/deeper"

        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let leaves = try #require(
            try decode(repository).windows[0].workspaces[0].tabs[0].paneTree?.leaves
        )
        #expect(leaves.first(where: { $0.uuid == background.id })?.cwd == "/background/deeper")
        // The focused pane's directory is untouched...
        #expect(leaves.first(where: { $0.uuid == focused.id })?.cwd == focusedCwdBefore)
        // ...and a background pane must never write `session.pwd`. That field
        // means "this session's directory" and is read by the sidebar folder
        // name and git branch, the sidebar filter, and the directory a new or
        // reopened tab inherits; letting every pane write it would make those
        // last-writer-wins.
        #expect(session.pwd == sessionPwdBefore)
    }

    // MARK: - Gate and second-instance behavior

    @Test func closedGateNeverWritesAFile() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = SessionPersistenceController(
            repository: repository,
            gate: SessionPersistenceGate(
                environment: [SessionPersistenceGate.killSwitchVariable: "1"],
                arguments: [],
                configEnabled: true
            ),
            registry: PendingHydrationRegistry(),
            controllersProvider: { [controller] }
        )

        #expect(!persistence.persistIfNeeded())
        persistence.persistNow()
        persistence.flush()
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))
    }

    @Test func secondInstanceStopsWriting() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        persistence.disableForSecondInstance()

        #expect(persistence.isDisabledBySecondInstance)
        #expect(!persistence.persistIfNeeded())
        persistence.persistNow()
        persistence.flush()
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))
    }

    @Test func terminateWriteIsUnconditional() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        // No `persistIfNeeded` first: quitting must still leave a file.
        persistence.persistNow()
        persistence.flush()
        #expect(FileManager.default.fileExists(atPath: repository.primaryURL.path))
        #expect(try decode(repository).windows.count == 1)
    }

    @Test func ownerFieldsRecordThisProcess() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }

        persistence.persistNow()
        persistence.flush()

        let snapshot = try decode(repository)
        #expect(snapshot.ownerPID == 4242)
        #expect(snapshot.ownerInstanceID != AppSessionSnapshot.unownedInstanceID)
    }
}
