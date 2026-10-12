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

    @MainActor
    private final class ManualScheduler {
        private var actions: [(@MainActor () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            actions.append(action)
        }

        func runAll() {
            let scheduled = actions
            actions.removeAll()
            scheduled.forEach { $0() }
        }

        var count: Int { actions.count }
    }

    private final class InstanceState: @unchecked Sendable {
        private let lock = NSLock()
        private var activePIDs: Set<Int32>

        init(activePIDs: Set<Int32>) {
            self.activePIDs = activePIDs
        }

        func contains(_ pid: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return activePIDs.contains(pid)
        }

        func setActive(_ pids: Set<Int32>) {
            lock.lock()
            defer { lock.unlock() }
            activePIDs = pids
        }
    }

    private final class UptimeState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64

        init(_ value: UInt64) {
            self.value = value
        }

        func read() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            self.value = value
        }
    }

    @MainActor
    private final class ControllerList {
        var controllers: [TerminalController]

        init(_ controllers: [TerminalController]) {
            self.controllers = controllers
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-persist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSurface(pwd: String? = nil, uuid: UUID = UUID()) -> Ghostty.SurfaceView? {
        guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
        let view = Ghostty.SurfaceView(
            app,
            baseConfig: nil,
            uuid: uuid,
            spawnsSurface: false
        )
        view.pwd = pwd
        return view
    }

    private func makeSession(pwd: String? = nil, paneUUID: UUID = UUID()) throws -> TerminalSessionState {
        let view = try #require(makeSurface(pwd: pwd, uuid: paneUUID))
        let session = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: view))
        session.focusedSurfaceID = view.id
        return session
    }

    private func inertRestoreConstructor() -> TerminalControllerGraphFactory.SurfaceConstructor {
        { config, uuid in
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }
    }

    private func makeRestoredController(_ window: WindowSnapshot) throws -> TerminalController {
        let graph = try #require(TerminalControllerGraphFactory.makeFromSnapshot(
            ghostty: TerminalControllerTestHarness.sharedApp,
            window: window,
            bindings: .init(
                registry: PendingHydrationRegistry(),
                construct: inertRestoreConstructor()
            )
        ))
        return TerminalController(TerminalControllerTestHarness.sharedApp, graph: graph)
    }

    private func makeController(
        workspaceName: String = "Workspace 1",
        tabCount: Int = 1,
        paneUUID: UUID? = nil
    ) throws -> TerminalController {
        let tabs = try (0..<tabCount).map { _ in
            try makeSession(pwd: "/tmp", paneUUID: paneUUID ?? UUID())
        }
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
        gate: SessionPersistenceGate? = nil,
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = 4242,
        queue: DispatchQueue = DispatchQueue(label: "chostty-tests.persistence"),
        isActive: @escaping () -> Bool = { true },
        isLiveInstance: @escaping @Sendable (Int32) -> Bool = { _ in false },
        otherInstanceRunning: @escaping () -> Bool = { false },
        uptime: @escaping @Sendable () -> UInt64 = { 100 },
        scheduler: ManualScheduler? = nil,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        controllers: @escaping () -> [TerminalController]
    ) -> SessionPersistenceController {
        SessionPersistenceController(
            repository: SessionSnapshotRepository(directory: directory),
            gate: gate ?? openGate(),
            registry: registry ?? PendingHydrationRegistry(),
            ownerInstanceID: ownerInstanceID,
            ownerPID: ownerPID,
            queue: queue,
            isActive: isActive,
            isLiveInstance: isLiveInstance,
            otherInstanceRunning: otherInstanceRunning,
            scheduleAfter: { delay, action in
                if let scheduler {
                    scheduler.schedule(delay, action)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                }
            },
            uptime: uptime,
            workspaceNotificationCenter: workspaceNotificationCenter,
            controllersProvider: controllers
        )
    }

    private func inject(
        _ persistence: SessionPersistenceController,
        into controller: TerminalController,
        registry: PendingHydrationRegistry? = nil
    ) {
        controller.injectRestoreBindings(.init(
            registry: registry ?? PendingHydrationRegistry(),
            construct: nil,
            persistence: persistence
        ))
    }

    private func decode(_ repository: SessionSnapshotRepository) throws -> AppSessionSnapshot {
        let data = try Data(contentsOf: repository.primaryURL)
        return try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
    }

    private func save(
        _ snapshot: AppSessionSnapshot,
        to repository: SessionSnapshotRepository
    ) throws {
        let policy = SessionSnapshotRepository.SavePolicy(
            claimEpoch: nil,
            selfInstanceID: snapshot.ownerInstanceID,
            selfPID: snapshot.ownerPID,
            deferredOwnerIDs: [],
            isLiveInstance: { _ in false },
            now: { 100 },
            retire: [],
            preserveStoredWindowsExcept: nil
        )
        _ = try repository.save(snapshot, policy: policy)
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

    private func tabSnapshot(_ tabID: UUID, in snapshot: AppSessionSnapshot) -> TabSnapshot? {
        snapshot.windows
            .flatMap(\.workspaces)
            .flatMap(\.tabs)
            .first { $0.id == tabID }
    }

    private func encodedTab(_ tab: TabSnapshot) throws -> Data {
        try SessionSnapshotRepository.encoder.encode(tab)
    }

    /// A pending tab as restoration builds it: an empty tree carrying the
    /// stored sidebar metadata.
    private func pendingSession(restoring stored: TabSnapshot) -> TerminalSessionState {
        let session = TerminalSessionState(id: stored.id, surfaceTree: SplitTree<Ghostty.SurfaceView>())
        session.titleOverride = stored.titleOverride
        session.tabColor = stored.tabColor
        return session
    }

    private func storedPendingTab(id: UUID) -> TabSnapshot {
        let left = PaneLeafSnapshot(uuid: UUID(), cwd: "/stored-a", title: "left")
        let right = PaneLeafSnapshot(uuid: UUID(), cwd: "/stored-b", title: "right")
        return TabSnapshot(
            id: id,
            titleOverride: "Stored",
            tabColor: String(TerminalTabColor.blue.rawValue),
            paneTree: .split(
                direction: .vertical,
                ratio: 0.4,
                left: .leaf(left),
                right: .leaf(right)
            ),
            focusedPaneID: right.uuid,
            zoomedPaneID: left.uuid
        )
    }

    private func restoredWindow(
        cwd: String?,
        titles: [String]
    ) -> WindowSnapshot {
        let leaves = (titles.isEmpty ? [""] : titles).map {
            PaneLeafSnapshot(uuid: UUID(), cwd: cwd, title: $0)
        }
        var paneTree = PaneTreeSnapshot.leaf(leaves[0])
        for leaf in leaves.dropFirst() {
            paneTree = .split(
                direction: .horizontal,
                ratio: 0.5,
                left: paneTree,
                right: .leaf(leaf)
            )
        }
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: paneTree,
            focusedPaneID: leaves.first?.uuid,
            zoomedPaneID: nil
        )
        let workspace = WorkspaceSnapshot(
            id: UUID(),
            name: "Restored",
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: [tab],
            selectedTabID: tab.id
        )
        return WindowSnapshot(
            physicalUUID: UUID(),
            selection: SelectionSnapshot(workspaceID: workspace.id, tabID: tab.id),
            workspaces: [workspace]
        )
    }

    // MARK: - Write scheduling

    @Test func restoredGraphSavedBeforeAnyOSC7KeepsEveryPaneCwd() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeRestoredController(restoredWindow(cwd: directory.path, titles: ["one", "two"]))
        let repository = SessionSnapshotRepository(directory: directory)
        let persistence = makePersistence(directory: directory) { [controller] }

        persistence.persistNow()

        let savedCwds = try decode(repository).windows[0].workspaces[0].tabs[0]
            .paneTree?.leaves.map(\.cwd)
        #expect(savedCwds == [directory.path, directory.path])
    }

    @Test func restoredTitlesSurviveAnImmediateFinalSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeRestoredController(restoredWindow(cwd: directory.path, titles: ["first", "second"]))
        let repository = SessionSnapshotRepository(directory: directory)
        let persistence = makePersistence(directory: directory) { [controller] }

        persistence.persistNow()

        let savedTitles = try decode(repository).windows[0].workspaces[0].tabs[0]
            .paneTree?.leaves.map(\.title)
        #expect(savedTitles == ["first", "second"])
    }

    @Test func liveTitleUpdatesSupersedeTheRestoredTitle() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeRestoredController(restoredWindow(cwd: directory.path, titles: ["restored"]))
        let view = try #require(controller.surfaceTree.first)
        let repository = SessionSnapshotRepository(directory: directory)
        let persistence = makePersistence(directory: directory) { [controller] }

        view.setTitle("live")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        persistence.persistNow()

        #expect(try decode(repository).windows[0].workspaces[0].tabs[0]
            .paneTree?.leaves.first?.title == "live")
    }

    @Test func duplicateTicksWhileAWriteIsPendingAreCoalesced() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let queue = DispatchQueue(label: "chostty-persist-tests.pending", qos: .utility)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            // Bound a regression to a failed expectation, not a hung test host.
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        let persistence = SessionPersistenceController(
            repository: repository,
            gate: openGate(),
            registry: PendingHydrationRegistry(),
            queue: queue,
            controllersProvider: { [controller] }
        )
        defer {
            release.signal()
            persistence.flush()
        }

        #expect(persistence.persistIfNeeded())
        #expect(!persistence.persistIfNeeded())
        #expect(!persistence.persistIfNeeded())
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))

        release.signal()
        persistence.flush()
        #expect(try decode(repository).windows.map(\.physicalUUID) == [controller.physicalUUID])
        #expect(!persistence.persistIfNeeded())
    }

    @Test func changedCursorQueuesBehindPendingWriteAndBecomesClean() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController(workspaceName: "Before")
        let queue = DispatchQueue(label: "chostty-persist-tests.changed", qos: .utility)
        let release = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        queue.async {
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        let persistence = SessionPersistenceController(
            repository: repository,
            gate: openGate(),
            registry: PendingHydrationRegistry(),
            queue: queue,
            controllersProvider: { [controller] }
        )
        defer {
            release.signal()
            releaseSecond.signal()
            persistence.flush()
        }

        #expect(persistence.persistIfNeeded())
        queue.async {
            firstFinished.signal()
            #expect(releaseSecond.wait(timeout: .now() + 5) == .success)
        }
        let store = controller.workspaceStore
        store.renameWorkspace(store.snapshot.workspaces[0].id, to: "After")
        #expect(persistence.persistIfNeeded())
        #expect(!persistence.persistIfNeeded())
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))

        release.signal()
        #expect(firstFinished.wait(timeout: .now() + 5) == .success)
        #expect(try decode(repository).windows[0].workspaces[0].name == "Before")
        // Completing the older cursor must not clear the newer reservation.
        #expect(!persistence.persistIfNeeded())
        releaseSecond.signal()
        persistence.flush()
        #expect(try decode(repository).windows[0].workspaces[0].name == "After")
        #expect(!persistence.persistIfNeeded())
    }

    // MARK: - Idle: no extra write, deterministic window order

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

    // MARK: - Structural commit is reflected

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

    // MARK: - Pending tabs are republished, never erased

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

    @Test func aFailedHydrationNeverErasesTheStoredPaneTree() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let live = try makeSession(pwd: "/live")
        let failedLeaf = PaneLeafSnapshot(uuid: UUID(), cwd: "/failed", title: nil)
        let stored = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .split(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: "/kept", title: nil)),
                right: .leaf(failedLeaf)
            ),
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let pending = TerminalSessionState(
            id: stored.id,
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [live, pending],
            selectedTabID: live.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: live.id)
        ))
        let registry = PendingHydrationRegistry()
        registry.store(stored, for: pending.id)
        controller.injectRestoreBindings(.init(
            registry: registry,
            construct: { _, uuid in
                guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
                let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: uuid, spawnsSurface: false)
                if uuid == failedLeaf.uuid {
                    view.error = Ghostty.Error.apiFailed
                }
                return view
            }
        ))

        #expect(controller.hydratePendingSession(pending) == .failed)

        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        let originalData = try Data(contentsOf: repository.primaryURL)

        let saved = try #require(
            try decode(repository).windows[0].workspaces[0].tabs.first { $0.id == pending.id }
        )
        #expect(saved.paneTree == stored.paneTree)
        #expect(try encodedTab(saved) == encodedTab(stored))
        for _ in 0..<3 {
            pending.bumpMetadataGeneration()
            #expect(persistence.persistIfNeeded())
            persistence.flush()
            #expect(try Data(contentsOf: repository.primaryURL) == originalData)
        }
    }

    @Test func pendingTabIsByteIdenticalInTheNextWrittenSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let live = try makeSession(pwd: "/live")
        let stored = storedPendingTab(id: UUID())
        let pending = pendingSession(restoring: stored)
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [live, pending],
            selectedTabID: live.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: live.id)
        ))
        let registry = PendingHydrationRegistry()
        registry.store(stored, for: pending.id)
        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let saved = try #require(tabSnapshot(pending.id, in: try decode(repository)))
        #expect(try encodedTab(saved) == encodedTab(stored))
    }

    @Test func renamingAPendingTabChangesOnlyItsTitleOverride() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let live = try makeSession(pwd: "/live")
        let stored = storedPendingTab(id: UUID())
        let pending = pendingSession(restoring: stored)
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [live, pending],
            selectedTabID: live.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: live.id)
        ))
        let registry = PendingHydrationRegistry()
        registry.store(stored, for: pending.id)
        controller.workspaceStore.renameTab(pending.id, to: "Renamed")
        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let expected = TabSnapshot(
            id: stored.id,
            titleOverride: "Renamed",
            tabColor: stored.tabColor,
            paneTree: stored.paneTree,
            focusedPaneID: stored.focusedPaneID,
            zoomedPaneID: stored.zoomedPaneID
        )
        let saved = try #require(tabSnapshot(pending.id, in: try decode(repository)))
        #expect(try encodedTab(saved) == encodedTab(expected))
    }

    @Test func recoloringAPendingTabChangesOnlyItsTabColor() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let live = try makeSession(pwd: "/live")
        let stored = storedPendingTab(id: UUID())
        let pending = pendingSession(restoring: stored)
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "W",
            tabs: [live, pending],
            selectedTabID: live.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: live.id)
        ))
        let registry = PendingHydrationRegistry()
        registry.store(stored, for: pending.id)
        controller.workspaceStore.setTabColor(pending.id, to: .green)
        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let expected = TabSnapshot(
            id: stored.id,
            titleOverride: stored.titleOverride,
            tabColor: String(TerminalTabColor.green.rawValue),
            paneTree: stored.paneTree,
            focusedPaneID: stored.focusedPaneID,
            zoomedPaneID: stored.zoomedPaneID
        )
        let saved = try #require(tabSnapshot(pending.id, in: try decode(repository)))
        #expect(try encodedTab(saved) == encodedTab(expected))
    }

    @Test func neverVisitedWorkspaceSurvivesRepeatedSavesByteIdentical() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let visited = try makeSession(pwd: "/visited")
        let stored = storedPendingTab(id: UUID())
        let pending = pendingSession(restoring: stored)
        let visitedWorkspace = WorkspaceSession(
            id: UUID(),
            name: "Visited",
            tabs: [visited],
            selectedTabID: visited.id
        )
        let neverVisitedWorkspace = WorkspaceSession(
            id: UUID(),
            name: "Never visited",
            tabs: [pending],
            selectedTabID: pending.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [visitedWorkspace, neverVisitedWorkspace],
            selection: Selection(workspaceID: visitedWorkspace.id, tabID: visited.id)
        ))
        let registry = PendingHydrationRegistry()
        registry.store(stored, for: pending.id)
        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }
        let expected = try encodedTab(stored)

        for save in 1...5 {
            controller.workspaceStore.renameWorkspace(visitedWorkspace.id, to: "Visited \(save)")
            #expect(persistence.persistIfNeeded())
            persistence.flush()
            let saved = try #require(tabSnapshot(pending.id, in: try decode(repository)))
            #expect(try encodedTab(saved) == expected)
        }
    }

    @Test func pendingTabMovedToAnotherWorkspaceKeepsItsStoredSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let sourceLive = try makeSession(pwd: "/source")
        let stored = storedPendingTab(id: UUID())
        let pending = pendingSession(restoring: stored)
        let destinationLive = try makeSession(pwd: "/destination")
        let sourceWorkspace = WorkspaceSession(
            id: UUID(),
            name: "Source",
            tabs: [sourceLive, pending],
            selectedTabID: sourceLive.id
        )
        let destinationWorkspace = WorkspaceSession(
            id: UUID(),
            name: "Destination",
            tabs: [destinationLive],
            selectedTabID: destinationLive.id
        )
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [sourceWorkspace, destinationWorkspace],
            selection: Selection(workspaceID: sourceWorkspace.id, tabID: sourceLive.id)
        ))
        let registry = PendingHydrationRegistry()
        registry.store(stored, for: pending.id)
        let persistence = makePersistence(directory: directory, registry: registry) { [controller] }

        controller.workspaceStore.moveTab(
            pending.id,
            toWorkspace: destinationWorkspace.id,
            at: 0
        )
        #expect(persistence.persistIfNeeded())
        persistence.flush()

        let snapshot = try decode(repository)
        let destination = try #require(
            snapshot.windows[0].workspaces.first { $0.id == destinationWorkspace.id }
        )
        let saved = try #require(destination.tabs.first { $0.id == pending.id })
        #expect(try encodedTab(saved) == encodedTab(stored))
    }

    // MARK: - Metadata changes move the counter; one write per tick

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

    // MARK: - Debounced structural saves

    @Test func scheduledSavesWithinTheDebounceWindowCoalesceIntoOneWrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let controller = try makeController()
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }

        persistence.scheduleSave()
        persistence.scheduleSave()
        scheduler.runAll()
        persistence.flush()

        #expect(FileManager.default.fileExists(atPath: repository.primaryURL.path))
    }

    @Test func closingATabSchedulesASaveThatLandsWithoutTheTimer() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let controller = try makeController(tabCount: 2)
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }
        inject(persistence, into: controller)

        let closingID = controller.workspaceStore.snapshot.workspaces[0].tabs[1].id
        _ = controller.workspaceStore.removeTab(closingID)
        scheduler.runAll()
        persistence.flush()

        let snapshot = try decode(repository)
        #expect(snapshot.windows[0].workspaces[0].tabs.count == 1)
    }

    @Test func switchingTabsSchedulesASave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let controller = try makeController(tabCount: 2)
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }
        inject(persistence, into: controller)

        let selectedID = controller.workspaceStore.snapshot.workspaces[0].tabs[1].id
        controller.workspaceStore.selectTab(selectedID)
        scheduler.runAll()
        persistence.flush()

        let saved = try decode(repository)
        let selection = try #require(saved.windows[0].selection)
        #expect(selection.tabID == selectedID)
    }

    @Test func renamingATabSchedulesASaveThroughTheStoreHook() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let controller = try makeController()
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }
        inject(persistence, into: controller)

        let tabID = controller.workspaceStore.snapshot.selection.tabID
        controller.workspaceStore.renameTab(tabID, to: "Renamed")
        scheduler.runAll()
        persistence.flush()

        let titleOverride = try decode(repository).windows[0].workspaces[0].tabs[0].titleOverride
        #expect(titleOverride == "Renamed")
    }

    @Test func splittingAPaneSchedulesASave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let controller = try makeController()
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }
        inject(persistence, into: controller)

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
        scheduler.runAll()
        persistence.flush()

        #expect(paneCount(try decode(repository)) == 2)
    }

    @Test func terminalTitleOrPwdChangesNeverScheduleASave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = ManualScheduler()
        let controller = try makeController()
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }
        inject(persistence, into: controller)
        let surface = try #require(controller.surfaceTree.first)

        surface.setTitle("title")
        surface.pwd = "/tmp/changed"
        settleTitles()

        #expect(scheduler.count == 0)
    }

    @Test func closedControllersAreExcludedFromTheDefaultProjection() throws {
        let controller = try makeController()
        #expect(TerminalController.all.contains { $0 === controller })
        controller.isWindowClosed = true

        #expect(!TerminalController.open.contains { $0 === controller })
    }

    @Test func terminationWritesOnceWithTheFullWindowSetAndFreezesLaterWrites() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let first = try makeController()
        let second = try makeController()
        var controllers = [first, second]
        let persistence = makePersistence(directory: directory) { controllers }

        persistence.beginTermination()
        let before = try Data(contentsOf: repository.primaryURL)
        controllers = [first]
        first.workspaceStore.renameWorkspace(first.workspaceStore.snapshot.selection.workspaceID, to: "After")
        persistence.scheduleSave()
        persistence.persistNow()

        let snapshot = try decode(repository)
        let after = try Data(contentsOf: repository.primaryURL)
        #expect(snapshot.windows.count == 2)
        #expect(after == before)
    }

    @Test func cancelledTerminationResumesSaving() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let controller = try makeController()
        let persistence = makePersistence(directory: directory, scheduler: scheduler) { [controller] }

        persistence.beginTermination()
        persistence.cancelTermination()
        controller.workspaceStore.renameWorkspace(
            controller.workspaceStore.snapshot.selection.workspaceID,
            to: "After"
        )
        scheduler.runAll()
        persistence.flush()

        let snapshot = try decode(repository)
        #expect(snapshot.windows[0].workspaces[0].name == "After")
    }

    @Test func restoredTitlesSurviveTheTerminationSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeRestoredController(
            restoredWindow(cwd: directory.path, titles: ["restored"])
        )
        let persistence = makePersistence(directory: directory) { [controller] }

        persistence.beginTermination()

        let title = try decode(repository).windows[0].workspaces[0].tabs[0]
            .paneTree?.leaves.first?.title
        #expect(title == "restored")
    }

    // MARK: - Splits are captured even though they bypass commit

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

    // MARK: - Non-representative pane titles

    /// Lets the surface title timer fire and the subscriptions deliver.
    private func settleTitles() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    /// A controller whose presented tab is split into the focused pane and a
    /// second, non-representative pane.
    private func makeSplitController() throws -> (TerminalController, Ghostty.SurfaceView, Ghostty.SurfaceView) {
        let controller = try makeController()
        let focused = try #require(controller.surfaceTree.first)
        let background = try #require(makeSurface(pwd: "/tmp"))
        controller.surfaceTree = SplitTree<Ghostty.SurfaceView>(
            root: .split(.init(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(view: focused),
                right: .leaf(view: background)
            )),
            zoomed: nil
        )
        return (controller, focused, background)
    }

    @Test func backgroundPaneTitleChangeIsSavedOnTheNextTick() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let (controller, _, background) = try makeSplitController()
        let persistence = makePersistence(directory: directory) { [controller] }
        settleTitles()
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(!persistence.persistIfNeeded())

        background.setTitle("background title")
        settleTitles()

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        let leaves = try #require(
            try decode(repository).windows[0].workspaces[0].tabs[0].paneTree?.leaves
        )
        #expect(leaves.first(where: { $0.uuid == background.id })?.title == "background title")
    }

    @Test func backgroundPaneTitleNeverOverwritesTheSessionTitle() throws {
        let (controller, focused, background) = try makeSplitController()
        focused.setTitle("focused title")
        settleTitles()
        let presentedID = try #require(controller.presentedSessionID)
        let session = try #require(controller.workspaceStore.session(forTabID: presentedID))
        let titleBefore = session.title
        #expect(titleBefore.contains("focused title"))

        background.setTitle("background title")
        settleTitles()

        #expect(session.title == titleBefore)
    }

    @Test func backgroundTabNonRepresentativePaneTitleIsSaved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let presented = try makeSession(pwd: "/tmp")
        let representative = try #require(makeSurface(pwd: "/tmp"))
        let second = try #require(makeSurface(pwd: "/tmp"))
        let background = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>(
                root: .split(.init(
                    direction: .horizontal,
                    ratio: 0.5,
                    left: .leaf(view: representative),
                    right: .leaf(view: second)
                )),
                zoomed: nil
            )
        )
        background.focusedSurfaceID = representative.id
        var workspace = WorkspaceSession(
            id: UUID(),
            name: "Workspace 1",
            tabs: [presented, background],
            selectedTabID: presented.id
        )
        workspace.color = .none
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: Selection(workspaceID: workspace.id, tabID: presented.id)
        ))
        let persistence = makePersistence(directory: directory) { [controller] }
        settleTitles()
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(!persistence.persistIfNeeded())
        let generationBefore = background.metadataGeneration

        second.setTitle("background tab pane")
        settleTitles()

        #expect(background.metadataGeneration == generationBefore + 1)
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        let leaves = try #require(
            try tabSnapshot(background.id, in: decode(repository))?.paneTree?.leaves
        )
        #expect(leaves.first(where: { $0.uuid == second.id })?.title == "background tab pane")
    }

    @Test func representativeTitleChangeBumpsTheGenerationExactlyOnce() throws {
        let controller = try makeController()
        let representative = try #require(controller.surfaceTree.first)
        settleTitles()
        let presentedID = try #require(controller.presentedSessionID)
        let session = try #require(controller.workspaceStore.session(forTabID: presentedID))
        let generationBefore = session.metadataGeneration

        representative.setTitle("representative title")
        settleTitles()

        #expect(session.metadataGeneration == generationBefore + 1)
        #expect(session.title.contains("representative title"))
    }

    // MARK: - Write rejection and retry

    @Test func emptyControllersCannotOverwritePrimaryOrScheduleInvalidWrites() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        var controllers = [controller]
        let persistence = makePersistence(directory: directory) { controllers }
        persistence.persistNow()
        let original = try Data(contentsOf: repository.primaryURL)
        #expect(!persistence.persistIfNeeded())

        // With no unopened windows the empty projection is offered once and
        // the repository leaves the last snapshot in place.
        controllers = []
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(!persistence.persistIfNeeded())
        #expect(try Data(contentsOf: repository.primaryURL) == original)

        persistence.persistNow()
        #expect(try Data(contentsOf: repository.primaryURL) == original)
        #expect(!persistence.persistIfNeeded())
    }

    @Test func failedWriteRetriesWithoutModelChangeAndThenBecomesClean() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the repository needs a directory produces a
        // real, deterministic I/O error without relying on permission bits.
        let blockedDirectory = directory.appendingPathComponent("blocked")
        let sentinel = Data("not a directory".utf8)
        try sentinel.write(to: blockedDirectory)
        let repository = SessionSnapshotRepository(directory: blockedDirectory)
        let controller = try makeController()
        let persistence = makePersistence(directory: blockedDirectory) { [controller] }

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(try Data(contentsOf: blockedDirectory) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))

        try FileManager.default.removeItem(at: blockedDirectory)
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        guard case .loaded(let snapshot, let source) = repository.load() else {
            Issue.record("the unchanged model must be retried after the I/O error")
            return
        }
        #expect(source == .primary)
        #expect(snapshot.windows.map(\.physicalUUID) == [controller.physicalUUID])
        #expect(!persistence.persistIfNeeded())
    }

    @Test func refusalIsReportedAsSaveHealthAndClearsAfterTheNextSuccessfulSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneUUID = UUID()
        let first = try makeController(paneUUID: paneUUID)
        let duplicate = try makeController(paneUUID: paneUUID)
        var controllers = [first, duplicate]
        let persistence = makePersistence(directory: directory) { controllers }

        persistence.persistNow()
        let refusedHealth = persistence.saveHealth
        #expect(refusedHealth == .refused(.duplicateIdentifier(paneUUID)))

        controllers = [first]
        let session = try #require(first.workspaceStore.allSessions.first)
        session.bumpMetadataGeneration()
        persistence.persistNow()
        let recoveredHealth = persistence.saveHealth
        #expect(recoveredHealth == .healthy)
    }

    /// Suspends the test so the main queue can deliver queued save results;
    /// a nested run loop would not drain it while this test runs on it.
    private func waitForSaveResults(
        _ persistence: SessionPersistenceController,
        until done: @MainActor () -> Bool = { false }
    ) async throws {
        persistence.flush()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            if done() { return }
        }
    }

    @Test func aSingleWriteFailureIsNotSurfacedButThreeInARowAre() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedDirectory = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let controller = try makeController()
        let persistence = makePersistence(directory: blockedDirectory) { [controller] }
        let session = try #require(controller.workspaceStore.allSessions.first)

        #expect(persistence.persistIfNeeded())
        try await waitForSaveResults(persistence)
        let firstFailureHealth = persistence.saveHealth
        #expect(firstFailureHealth == .healthy)

        session.bumpMetadataGeneration()
        #expect(persistence.persistIfNeeded())
        try await waitForSaveResults(persistence)
        let secondFailureHealth = persistence.saveHealth
        #expect(secondFailureHealth == .healthy)

        session.bumpMetadataGeneration()
        #expect(persistence.persistIfNeeded())
        try await waitForSaveResults(persistence) { persistence.saveHealth != .healthy }
        let thirdFailureHealth = persistence.saveHealth
        #expect(thirdFailureHealth == .failing(consecutiveFailures: 3))
    }

    @Test func refusedSnapshotWaitsForStateChangeBeforeRetrying() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneUUID = UUID()
        let first = try makeController(paneUUID: paneUUID)
        let duplicate = try makeController(paneUUID: paneUUID)
        var controllers = [first, duplicate]
        let repository = SessionSnapshotRepository(directory: directory)
        let persistence = makePersistence(directory: directory) { controllers }

        #expect(persistence.persistIfNeeded())
        persistence.flush()
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))
        #expect(!persistence.persistIfNeeded())

        controllers = [first]
        #expect(persistence.persistIfNeeded())
        persistence.flush()
        guard case .loaded(let snapshot, source: .primary) = repository.load() else {
            Issue.record("a changed valid cursor must save after a refusal")
            return
        }
        #expect(snapshot.windows.map(\.physicalUUID) == [first.physicalUUID])
        #expect(!persistence.persistIfNeeded())
    }

    @Test func healthChangesPostOneNotificationPerTransition() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paneUUID = UUID()
        let first = try makeController(paneUUID: paneUUID)
        let duplicate = try makeController(paneUUID: paneUUID)
        var controllers = [first, duplicate]
        let persistence = makePersistence(directory: directory) { controllers }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SessionPersistenceController.healthDidChange,
            object: persistence,
            queue: .main
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        persistence.persistNow()
        persistence.persistNow()
        controllers = [first]
        let session = try #require(first.workspaceStore.allSessions.first)
        session.bumpMetadataGeneration()
        persistence.persistNow()

        #expect(notifications == 2)
    }

    @Test func anUnrecordableLedgerIsReportedUntilARecordSucceeds() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockDirectory = directory.appendingPathComponent(
            SessionSnapshotRepository.restoreAttemptsLockFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SessionPersistenceController.healthDidChange,
            object: persistence,
            queue: .main
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let firstAttempt = persistence.beginRestoreAttempt(.window, [UUID()])
        #expect(firstAttempt == .unrecorded)
        #expect(persistence.restoreAttemptsUnavailable)
        #expect(notifications == 1)

        try FileManager.default.removeItem(at: lockDirectory)
        let secondAttempt = persistence.beginRestoreAttempt(.window, [UUID()])
        guard case .recorded = secondAttempt else {
            Issue.record("the restore attempt should be recorded after the lock path is fixed")
            return
        }
        #expect(!persistence.restoreAttemptsUnavailable)
        #expect(notifications == 2)
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

    @Test func sidebarSyncSavesAnAbsentSnapshotWithoutChangingLiveState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController(workspaceName: "Live")
        let persistence = makePersistence(directory: directory) { [controller] }
        let liveBeforeSave = persistence.snapshot(from: [controller])

        let absent = persistence.sidebarSyncInspection()
        #expect(absent.status == .absent)
        #expect(absent.canSynchronize)
        #expect(absent.synchronizationAvailability == .available)

        let synchronized = persistence.synchronizeSidebarState()
        #expect(synchronized.status == .synchronized)
        #expect(synchronized.current?.windows == synchronized.saved?.windows)
        #expect(try decode(repository).windows == liveBeforeSave.windows)
        #expect(persistence.snapshot(from: [controller]).windows == liveBeforeSave.windows)
    }

    @Test func sidebarSyncReportsLiveChangesAndRefreshesAfterManualSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController(workspaceName: "Before")
        let persistence = makePersistence(directory: directory) { [controller] }

        #expect(persistence.synchronizeSidebarState().status == .synchronized)

        let store = controller.workspaceStore
        store.renameWorkspace(store.snapshot.workspaces[0].id, to: "After")

        let outOfSync = persistence.sidebarSyncInspection()
        #expect(outOfSync.status == .outOfSync)
        #expect(outOfSync.current?.windows != outOfSync.saved?.windows)

        let synchronized = persistence.synchronizeSidebarState()
        #expect(synchronized.status == .synchronized)
        #expect(try decode(repository).windows[0].workspaces[0].name == "After")
    }

    @Test func sidebarSyncIgnoresSnapshotOwnerBookkeeping() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let persistence = makePersistence(directory: directory) { [controller] }
        let live = persistence.snapshot(from: [controller])
        let saved = AppSessionSnapshot(
            ownerInstanceID: UUID(),
            ownerPID: 9999,
            windows: live.windows
        )
        let policy = SessionSnapshotRepository.SavePolicy(
            claimEpoch: nil,
            selfInstanceID: saved.ownerInstanceID,
            selfPID: saved.ownerPID,
            deferredOwnerIDs: [],
            isLiveInstance: { _ in false },
            now: { 100 },
            retire: []
        )
        #expect(try repository.save(saved, policy: policy).outcome == .written)

        let inspection = persistence.sidebarSyncInspection()
        #expect(inspection.status == .synchronized)
        #expect(inspection.current?.ownerInstanceID != inspection.saved?.ownerInstanceID)
        #expect(inspection.current?.ownerPID != inspection.saved?.ownerPID)
    }

    @Test func disabledSidebarSyncCannotWrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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

        let inspection = persistence.sidebarSyncInspection()
        #expect(inspection.status == .absent)
        #expect(!inspection.canSynchronize)
        #expect(inspection.synchronizationAvailability == .persistenceDisabled)
        #expect(persistence.synchronizeSidebarState() == inspection)
        #expect(!FileManager.default.fileExists(atPath: repository.primaryURL.path))
    }

    @Test func inactiveInstanceYieldsToTheInstanceThatClaimedTheFile() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let active = makePersistence(directory: directory, ownerPID: 777, isActive: { true }, isLiveInstance: { $0 == 4242 }, controllers: {
            [controller]
        })
        active.noteActivation()
        active.persistNow()
        let passive = makePersistence(directory: directory, isActive: { false }, isLiveInstance: { $0 == 777 }, controllers: {
            [controller]
        })
        #expect(passive.persistIfNeeded())
        passive.flush()
        #expect(try decode(repository).ownerPID == 777)
    }

    @Test func activeInstanceWritesOverALiveInactiveOwner() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let inactive = makePersistence(
            directory: directory,
            ownerPID: 4242,
            isActive: { false },
            isLiveInstance: { $0 == 777 },
            controllers: { [controller] }
        )
        let active = makePersistence(
            directory: directory,
            ownerPID: 777,
            isActive: { true },
            isLiveInstance: { $0 == 4242 },
            controllers: { [controller] }
        )

        inactive.persistNow()
        active.noteActivation()
        active.persistNow()

        #expect(try decode(repository).ownerPID == 777)
    }

    @Test func ownerChangesOnlyWhenActivationChanges() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let active = makePersistence(
            directory: directory,
            ownerPID: 4242,
            isActive: { true },
            isLiveInstance: { _ in false },
            controllers: { [controller] }
        )

        active.noteActivation()
        active.persistNow()
        let first = try Data(contentsOf: repository.primaryURL)
        active.persistNow()
        #expect(try Data(contentsOf: repository.primaryURL) == first)
    }

    @Test func yieldsNeverDegradeSaveHealth() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController()
        let owner = makePersistence(
            directory: directory,
            ownerPID: 777,
            isActive: { true },
            isLiveInstance: { $0 == 4242 },
            controllers: { [controller] }
        )
        owner.noteActivation()
        owner.persistNow()
        let passive = makePersistence(
            directory: directory,
            ownerPID: 4242,
            isActive: { false },
            isLiveInstance: { $0 == 777 },
            controllers: { [controller] }
        )

        passive.persistNow()
        #expect(passive.saveHealth == .healthy)
    }

    @Test func passiveInstanceStaysPassiveAfterTheOwnerExitsUntilActivated() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let ownerID = UUID()
        let owner = makePersistence(
            directory: directory,
            ownerInstanceID: ownerID,
            ownerPID: 777,
            isActive: { true },
            isLiveInstance: { _ in false },
            controllers: { [controller] }
        )
        owner.noteActivation()
        owner.persistNow()
        let state = InstanceState(activePIDs: [777])
        let passive = makePersistence(
            directory: directory,
            isActive: { false },
            isLiveInstance: { state.contains($0) },
            controllers: { [controller] }
        )
        let stored = try decode(repository)
        #expect(passive.adoptOwnership(of: stored))
        state.setActive([])

        passive.persistNow()
        #expect(try decode(repository).ownerInstanceID == ownerID)
    }

    @Test func anIdlePassiveInstanceNeverTouchesTheDisk() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let owner = makePersistence(
            directory: directory,
            ownerPID: 777,
            isActive: { true },
            isLiveInstance: { _ in false },
            controllers: { [controller] }
        )
        owner.noteActivation()
        owner.persistNow()
        let original = try Data(contentsOf: repository.primaryURL)
        let passive = makePersistence(
            directory: directory,
            isActive: { false },
            isLiveInstance: { $0 == 777 },
            controllers: { [controller] }
        )
        let stored = try decode(repository)
        #expect(passive.adoptOwnership(of: stored))

        #expect(!passive.persistIfNeeded())
        #expect(try Data(contentsOf: repository.primaryURL) == original)
    }

    @Test func aStaleQueuedClaimYieldsToANewerActivation() async throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let first = try makeController(workspaceName: "A")
        let second = try makeController(workspaceName: "B")
        settleTitles()
        let scheduler = ManualScheduler()
        let active = InstanceState(activePIDs: [4242])
        // Uptime is one system clock shared by every instance.
        let clock = UptimeState(10)
        let aQueue = DispatchQueue(label: "chostty-tests.stale-claim-a")
        let hold = DispatchSemaphore(value: 0)
        aQueue.async { hold.wait() }
        let a = makePersistence(
            directory: directory,
            ownerPID: 4242,
            queue: aQueue,
            isActive: { active.contains(4242) },
            isLiveInstance: { active.contains($0) },
            uptime: { clock.read() },
            scheduler: scheduler,
            controllers: { [first] }
        )
        let b = makePersistence(
            directory: directory,
            ownerPID: 777,
            isActive: { active.contains(777) },
            isLiveInstance: { active.contains($0) },
            uptime: { clock.read() },
            scheduler: scheduler,
            controllers: { [second] }
        )

        a.noteActivation()
        #expect(a.persistIfNeeded())
        clock.set(20)
        active.setActive([777])
        b.noteActivation()
        b.persistNow()
        let expected = try Data(contentsOf: repository.primaryURL)

        hold.signal()
        try await waitForSaveResults(a, until: { a.isPassive })
        #expect(try Data(contentsOf: repository.primaryURL) == expected)
        #expect(try decode(repository).ownerPID == 777)
    }

    @Test func aYieldedResultArrivingAfterANewerActivationIsIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        settleTitles()
        let active = InstanceState(activePIDs: [4242])
        // Uptime is one system clock shared by every instance.
        let clock = UptimeState(10)
        let scheduler = ManualScheduler()
        let queue = DispatchQueue(label: "chostty-tests.stale-yield")
        let hold = DispatchSemaphore(value: 0)
        queue.async { hold.wait() }
        let owner = makePersistence(
            directory: directory,
            ownerPID: 777,
            isActive: { active.contains(777) },
            isLiveInstance: { active.contains($0) },
            uptime: { clock.read() },
            scheduler: scheduler,
            controllers: { [controller] }
        )
        let candidate = makePersistence(
            directory: directory,
            ownerPID: 4242,
            queue: queue,
            isActive: { active.contains(4242) },
            isLiveInstance: { active.contains($0) },
            uptime: { clock.read() },
            scheduler: scheduler,
            controllers: { [controller] }
        )

        candidate.noteActivation()
        #expect(candidate.persistIfNeeded())
        clock.set(20)
        active.setActive([777])
        owner.noteActivation()
        owner.persistNow()
        let expected = try Data(contentsOf: repository.primaryURL)
        clock.set(30)
        active.setActive([777, 4242])
        candidate.noteActivation()
        hold.signal()
        try await waitForSaveResults(candidate)
        #expect(!candidate.isPassive)
        #expect(candidate.deferredOwners.isEmpty)
        #expect(try Data(contentsOf: repository.primaryURL) == expected)
    }

    @Test func aPassiveInstanceStillRetiresItsOwnClosedWindow() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let closed = try makeController(workspaceName: "Closed")
        let live = try makeController(workspaceName: "Live")
        let ownerID = UUID()
        let seeder = makePersistence(directory: directory) { [] }
        let controllers = ControllerList([closed])
        let observer = makePersistence(
            directory: directory,
            ownerPID: 4242,
            isActive: { false },
            isLiveInstance: { $0 == 777 },
            controllers: { controllers.controllers }
        )
        let observed = seeder.snapshot(from: [closed, live])
        let stored = AppSessionSnapshot(
            ownerInstanceID: ownerID,
            ownerPID: 777,
            windows: observed.windows
        )
        let policy = SessionSnapshotRepository.SavePolicy(
            claimEpoch: nil,
            selfInstanceID: ownerID,
            selfPID: 777,
            deferredOwnerIDs: [],
            isLiveInstance: { _ in false },
            now: { 100 },
            retire: []
        )
        _ = try repository.save(stored, policy: policy)

        observer.persistNow()
        controllers.controllers = [live]
        let retained = try #require(observed.windows.first { $0.physicalUUID == live.physicalUUID })
        let retainedBytes = try SessionSnapshotRepository.encoder.encode(retained)
        observer.persistNow()
        let after = try decode(repository)
        #expect(after.ownerInstanceID == ownerID)
        #expect(after.ownerPID == 777)
        #expect(after.windows == [retained])
        #expect(try SessionSnapshotRepository.encoder.encode(after.windows[0]) == retainedBytes)
    }

    @Test func aRetireDeclinedByTheEmptyFileGuardIsRetriedLater() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let closed = try makeController(workspaceName: "Closed")
        let added = try makeController(workspaceName: "Added")
        settleTitles()
        let active = InstanceState(activePIDs: [777])
        let clock = UptimeState(10)
        let scheduler = ManualScheduler()
        let ownerID = UUID()
        let ownerControllers = ControllerList([closed])
        let passiveControllers = ControllerList([closed])
        let owner = makePersistence(
            directory: directory,
            ownerInstanceID: ownerID,
            ownerPID: 777,
            isActive: { active.contains(777) },
            isLiveInstance: { active.contains($0) },
            uptime: { clock.read() },
            scheduler: scheduler,
            controllers: { ownerControllers.controllers }
        )
        let passive = makePersistence(
            directory: directory,
            ownerPID: 4242,
            isActive: { false },
            isLiveInstance: { active.contains($0) },
            uptime: { clock.read() },
            scheduler: scheduler,
            controllers: { passiveControllers.controllers }
        )

        owner.noteActivation()
        owner.persistNow()
        let stored = try decode(repository)
        let didAdoptOwnership = passive.adoptOwnership(of: stored)
        #expect(didAdoptOwnership)
        passive.persistNow()

        passiveControllers.controllers = []
        passive.persistNow()
        let afterDeclinedRetire = try decode(repository)
        let declinedWindowIDs = Set(afterDeclinedRetire.windows.map(\.physicalUUID))
        #expect(declinedWindowIDs == [closed.physicalUUID])

        ownerControllers.controllers = [closed, added]
        owner.persistNow()
        passive.persistNow()

        let afterRetriedRetire = try decode(repository)
        let retriedWindowIDs = Set(afterRetriedRetire.windows.map(\.physicalUUID))
        #expect(retriedWindowIDs == [added.physicalUUID])
    }

    @Test func finalSaveOfAnInactiveInstanceDoesNotOverwriteAnInstanceItDeferredTo() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let controller = try makeController()
        let owner = makePersistence(
            directory: directory,
            ownerPID: 777,
            isActive: { true },
            isLiveInstance: { $0 == 4242 },
            controllers: { [controller] }
        )
        owner.noteActivation()
        owner.persistNow()
        let expected = try Data(contentsOf: repository.primaryURL)
        let passive = makePersistence(
            directory: directory,
            isActive: { false },
            isLiveInstance: { $0 == 777 },
            controllers: { [controller] }
        )
        let stored = try decode(repository)
        #expect(passive.adoptOwnership(of: stored))

        passive.beginTermination()
        #expect(try Data(contentsOf: repository.primaryURL) == expected)
    }

    @Test func activationClearsARejectedCursorAndForcesOneWrite() throws {
        let directory = try makeTemporaryDirectory()
        let first = try makeController(paneUUID: UUID())
        let duplicatePaneID = first.workspaceStore.allSessions[0].surfaceTree.first!.id
        let duplicate = try makeController(paneUUID: duplicatePaneID)
        settleTitles()
        let scheduler = ManualScheduler()
        let persistence = makePersistence(
            directory: directory,
            isActive: { true },
            scheduler: scheduler,
            controllers: { [first, duplicate] }
        )

        persistence.persistNow()
        let refusedHealth = persistence.saveHealth
        #expect(refusedHealth == .refused(.duplicateIdentifier(duplicatePaneID)))
        #expect(!persistence.persistIfNeeded())
        persistence.noteActivation()
        #expect(persistence.persistIfNeeded())
    }

    @Test func aReusedPidOfAnotherProgramIsNotAnOwner() {
        // launchd is alive and owned by root, which `kill(pid, 0)` reports as
        // alive through EPERM; it is still not a Chostty instance.
        #expect(!SessionPersistenceController.isLiveAppInstance(1))
        #expect(!SessionPersistenceController.isLiveAppInstance(0))
        #expect(!SessionPersistenceController.isLiveAppInstance(-1))
        #expect(!SessionPersistenceController.isLiveAppInstance(Int32(ProcessInfo.processInfo.processIdentifier)))
    }

    @Test func finalSaveOfTheActiveInstanceAlwaysWrites() throws {
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

    // MARK: - Tab tear-off projection

    @Test func detachedTabProjectsExactlyOnceAcrossBothWindows() throws {
        // A torn-off tab must appear exactly once in the session projection:
        // in the destination window, never duplicated in the source. No save
        // runs here — the projection is what the next timer tick persists.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(tabCount: 2)
        let moving = controller.workspaceStore.allSessions[0]

        let destination = try #require(
            controller.detachTabToNewWindow(tabID: moving.id, screenPoint: nil))
        let persistence = makePersistence(directory: directory) {
            [controller, destination]
        }

        let snapshot = persistence.snapshot(from: [controller, destination])
        let allTabIDs = snapshot.windows
            .flatMap(\.workspaces)
            .flatMap(\.tabs)
            .map(\.id)

        #expect(snapshot.windows.count == 2)
        #expect(allTabIDs.filter { $0 == moving.id }.count == 1)
        #expect(allTabIDs.count == 2)
    }

    // MARK: - Dormant windows

    @Test func bootDecisionAppliesEveryWindowOnAnOrdinaryLaunch() {
        let windows = [
            restoredWindow(cwd: "/tmp", titles: ["one"]),
            restoredWindow(cwd: "/tmp", titles: ["two"]),
        ]
        let decision = SessionPersistenceController.bootDecision(
            windows: windows,
            quarantinedWindows: [],
            mayApplyOnBoot: true,
            anotherInstanceRunning: false,
            hasOpenWindow: false,
            initialWindow: true
        )
        #expect(decision.apply == windows)
        #expect(decision.keepDormant.isEmpty)
        #expect(decision.reason == nil)
    }

    @Test func bootDecisionKeepsEveryWindowDormantWhenAWindowIsAlreadyOpen() {
        let windows = [restoredWindow(cwd: "/tmp", titles: ["one"])]
        let decision = SessionPersistenceController.bootDecision(
            windows: windows,
            quarantinedWindows: [],
            mayApplyOnBoot: true,
            anotherInstanceRunning: false,
            hasOpenWindow: true,
            initialWindow: true
        )
        #expect(decision.apply.isEmpty)
        #expect(decision.keepDormant == windows)
        #expect(decision.reason == .windowAlreadyOpen)
    }

    @Test func bootDecisionKeepsEveryWindowDormantWhenInitialWindowIsOff() {
        let windows = [restoredWindow(cwd: "/tmp", titles: ["one"])]
        let decision = SessionPersistenceController.bootDecision(
            windows: windows,
            quarantinedWindows: [],
            mayApplyOnBoot: true,
            anotherInstanceRunning: false,
            hasOpenWindow: false,
            initialWindow: false
        )
        #expect(decision.keepDormant == windows)
        #expect(decision.reason == .initialWindowDisabled)
    }

    @Test func bootDecisionKeepsEveryWindowDormantForAnExplicitOpenIntent() {
        let windows = [restoredWindow(cwd: "/tmp", titles: ["one"])]
        let decision = SessionPersistenceController.bootDecision(
            windows: windows,
            quarantinedWindows: [],
            mayApplyOnBoot: false,
            anotherInstanceRunning: false,
            hasOpenWindow: false,
            initialWindow: true
        )
        #expect(decision.keepDormant == windows)
        #expect(decision.reason == .explicitOpenIntent)
    }

    @Test func bootDecisionKeepsEveryWindowDormantWhileAnotherInstanceRuns() {
        let windows = [restoredWindow(cwd: "/tmp", titles: ["one"])]
        let decision = SessionPersistenceController.bootDecision(
            windows: windows,
            quarantinedWindows: [],
            mayApplyOnBoot: true,
            anotherInstanceRunning: true,
            hasOpenWindow: false,
            initialWindow: true
        )
        #expect(decision.keepDormant == windows)
        #expect(decision.reason == .anotherInstanceRunning)
    }

    @Test func bootDecisionNeverAppliesAQuarantinedWindow() {
        let healthy = restoredWindow(cwd: "/tmp", titles: ["healthy"])
        let quarantined = restoredWindow(cwd: "/tmp", titles: ["quarantined"])
        let decision = SessionPersistenceController.bootDecision(
            windows: [healthy, quarantined],
            quarantinedWindows: [quarantined.physicalUUID],
            mayApplyOnBoot: true,
            anotherInstanceRunning: false,
            hasOpenWindow: false,
            initialWindow: true
        )
        #expect(decision.apply == [healthy])
        #expect(decision.keepDormant == [quarantined])
        #expect(decision.reason == .quarantined)
    }

    @Test func fileFirstLaunchKeepsTheStoredWindowsByteIdenticalNextToTheNewWindow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let storedBytes = try SessionSnapshotRepository.encoder.encode(stored)
        let new = try makeController(workspaceName: "New")
        let persistence = makePersistence(directory: directory) { [new] }

        persistence.persistNow()

        let saved = try decode(repository)
        let retained = try #require(saved.windows.first { $0.physicalUUID == stored.physicalUUID })
        let retainedBytes = try SessionSnapshotRepository.encoder.encode(retained)
        #expect(retainedBytes == storedBytes)
        #expect(saved.windows.count == 2)
    }

    @Test func explicitOpenLaunchSavesItsWindowAndKeepsTheStoredSidebar() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let storedBytes = try SessionSnapshotRepository.encoder.encode(stored)
        let gate = SessionPersistenceGate(environment: [:], arguments: ["-e", "top"], configEnabled: true)
        let opened = try makeController(workspaceName: "Opened")
        let persistence = makePersistence(directory: directory, gate: gate) { [opened] }

        let adopted = try #require(persistence.adoptStoredSession(
            liveWindowIDs: [opened.physicalUUID]
        ))
        let decision = SessionPersistenceController.bootDecision(
            windows: adopted.snapshot.windows,
            quarantinedWindows: [],
            mayApplyOnBoot: gate.shouldApplyOnBoot,
            anotherInstanceRunning: false,
            hasOpenWindow: true,
            initialWindow: true
        )
        #expect(decision.apply.isEmpty)
        #expect(decision.reason == .explicitOpenIntent)

        persistence.persistNow()

        let saved = try decode(repository)
        let savedIDs = Set(saved.windows.map(\.physicalUUID))
        #expect(savedIDs == [stored.physicalUUID, opened.physicalUUID])
        let retained = try #require(saved.windows.first { $0.physicalUUID == stored.physicalUUID })
        let retainedBytes = try SessionSnapshotRepository.encoder.encode(retained)
        #expect(retainedBytes == storedBytes)
        #expect(persistence.reopenableWindowIDs == [stored.physicalUUID])
    }

    @Test func unopenedWindowsSurviveRepeatedSavesByteIdentical() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let storedBytes = try SessionSnapshotRepository.encoder.encode(stored)
        let live = try makeController(workspaceName: "Live")
        let persistence = makePersistence(directory: directory) { [live] }

        persistence.persistNow()
        persistence.persistNow()

        let saved = try decode(repository)
        let retained = try #require(saved.windows.first {
            $0.physicalUUID == stored.physicalUUID
        })
        let retainedBytes = try SessionSnapshotRepository.encoder.encode(retained)
        #expect(retainedBytes == storedBytes)
    }

    @Test func closingAPromotedWindowRemovesItFromTheFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let promoted = restoredWindow(cwd: directory.path, titles: ["promoted"])
        let unopened = restoredWindow(cwd: directory.path, titles: ["unopened"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [promoted, unopened]), to: repository)
        let controller = try makeRestoredController(promoted)
        let controllers = ControllerList([controller])
        let persistence = makePersistence(directory: directory, controllers: { controllers.controllers })
        _ = persistence.adoptStoredSession(liveWindowIDs: [])
        persistence.claimDormant(promoted.physicalUUID)
        persistence.persistNow()
        controllers.controllers = []

        persistence.persistNow()

        let saved = try decode(repository)
        #expect(saved.windows == [unopened])
    }

    @Test func closingTheLastLiveWindowLeavesOnlyTheUnopenedWindows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let promoted = restoredWindow(cwd: directory.path, titles: ["promoted"])
        let unopened = restoredWindow(cwd: directory.path, titles: ["unopened"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [promoted, unopened]), to: repository)
        let controller = try makeRestoredController(promoted)
        let controllers = ControllerList([controller])
        let persistence = makePersistence(directory: directory, controllers: { controllers.controllers })
        _ = persistence.adoptStoredSession(liveWindowIDs: [])
        persistence.claimDormant(promoted.physicalUUID)
        controllers.controllers = []

        persistence.persistNow()

        let saved = try decode(repository)
        #expect(saved.windows == [unopened])
    }

    @Test func closingTheLastLiveWindowWithNothingUnopenedKeepsTheLastSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["only"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let controller = try makeRestoredController(stored)
        let controllers = ControllerList([controller])
        let persistence = makePersistence(directory: directory, controllers: { controllers.controllers })
        _ = persistence.adoptStoredSession(liveWindowIDs: [])
        persistence.claimDormant(stored.physicalUUID)
        persistence.persistNow()
        let beforeClose = try Data(contentsOf: repository.primaryURL)
        controllers.controllers = []

        persistence.persistNow()

        let afterClose = try Data(contentsOf: repository.primaryURL)
        #expect(afterClose == beforeClose)
    }

    @Test func aWriterNeverReplacesAWindowItNeverHadLiveWithAnOlderCopy() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeController(workspaceName: "First")
        let second = try makeController(workspaceName: "Second")
        let a = makePersistence(directory: directory, controllers: { [first] })
        let b = makePersistence(directory: directory, controllers: { [second] })
        a.persistNow()
        b.persistNow()
        let afterSecondWriter = try decode(SessionSnapshotRepository(directory: directory))
        let secondWindow = try #require(afterSecondWriter.windows.first {
            $0.physicalUUID == second.physicalUUID
        })
        let secondBytes = try SessionSnapshotRepository.encoder.encode(secondWindow)

        a.persistNow()

        let saved = try decode(SessionSnapshotRepository(directory: directory))
        let retained = try #require(saved.windows.first { $0.physicalUUID == second.physicalUUID })
        let retainedBytes = try SessionSnapshotRepository.encoder.encode(retained)
        #expect(retainedBytes == secondBytes)
    }

    @Test func detachedTabWithAUniqueSiblingSurvivesAConflictingWriter() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeController(tabCount: 2)
        let moving = source.workspaceStore.allSessions[0]
        let sibling = try #require(source.workspaceStore.allSessions.first { $0.id != moving.id })
        let detached = try #require(source.detachTabToNewWindow(tabID: moving.id, screenPoint: nil))
        let writerA = makePersistence(directory: directory) { [source, detached] }
        writerA.persistNow()
        let stale = try makeController(tabCount: 1, paneUUID: moving.surfaceTree.first?.id)
        let writerB = makePersistence(directory: directory) { [stale] }

        writerB.persistNow()

        let restarted = SessionSnapshotRepository(directory: directory)
        let load = restarted.load()
        let saved: AppSessionSnapshot?
        if case .loaded(let snapshot, _) = load {
            saved = snapshot
        } else {
            saved = nil
        }
        let snapshot = try #require(saved)
        #expect(snapshot.windows.contains { $0.physicalUUID == detached.physicalUUID })
        #expect(snapshot.windows.flatMap(\.workspaces).flatMap(\.tabs).contains { $0.id == moving.id })
        #expect(snapshot.windows.flatMap(\.workspaces).flatMap(\.tabs).contains { $0.id == sibling.id })
    }

    @Test func inspectionCountsPreservedWindowsAsSynchronized() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let live = try makeController(workspaceName: "Live")
        let persistence = makePersistence(directory: directory) { [live] }
        persistence.persistNow()

        let inspection = persistence.sidebarSyncInspection()
        #expect(inspection.status == .synchronized)
        #expect(inspection.current?.windows.count == 2)
        #expect(inspection.reopenableWindowCount == 1)
    }

    @Test func adoptingAStoredSessionRecordsDormantWindowsWithoutBuildingAnything() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let persistence = makePersistence(directory: directory) { [] }

        let adopted = persistence.adoptStoredSession(liveWindowIDs: [])

        #expect(adopted?.snapshot.windows == [stored])
        #expect(persistence.dormantWindowIDs == [stored.physicalUUID])
        #expect(persistence.claimedWindowIDs.isEmpty)
    }

    @Test func reopenIsNotOfferedWhileAnotherInstanceRuns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let persistence = makePersistence(
            directory: directory,
            otherInstanceRunning: { true },
            controllers: { [] }
        )
        _ = persistence.adoptStoredSession(liveWindowIDs: [])

        #expect(persistence.reopenableWindowIDs.isEmpty)
        #expect(persistence.dockReopenCandidateIDs.isEmpty)
    }

    @Test func aSecondInstanceNeverAppliesWindowsOwnedByALiveInstance() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let persistence = makePersistence(
            directory: directory,
            otherInstanceRunning: { true },
            controllers: { [] }
        )
        let adopted = try #require(persistence.adoptStoredSession(liveWindowIDs: []))

        let decision = SessionPersistenceController.bootDecision(
            windows: adopted.snapshot.windows,
            quarantinedWindows: [],
            mayApplyOnBoot: true,
            anotherInstanceRunning: true,
            hasOpenWindow: false,
            initialWindow: true
        )
        #expect(decision.apply.isEmpty)
        #expect(decision.keepDormant == [stored])
    }

    @Test func dormantListRefreshesWhenAnotherInstanceQuits() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let stored = restoredWindow(cwd: directory.path, titles: ["stored"])
        try save(AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored]), to: repository)
        let added = restoredWindow(cwd: directory.path, titles: ["added"])
        var otherInstanceRunning = true
        let workspaceNotificationCenter = NotificationCenter()
        let persistence = makePersistence(
            directory: directory,
            otherInstanceRunning: { otherInstanceRunning },
            workspaceNotificationCenter: workspaceNotificationCenter,
            controllers: { [] }
        )
        _ = persistence.adoptStoredSession(liveWindowIDs: [])
        #expect(persistence.reopenableWindowIDs.isEmpty)

        try save(
            AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 777, windows: [stored, added]),
            to: repository
        )
        otherInstanceRunning = false
        persistence.start()
        let terminationUserInfo: [AnyHashable: Any] = [
            NSWorkspace.applicationUserInfoKey: NSRunningApplication.current,
        ]
        workspaceNotificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: terminationUserInfo
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        persistence.stop()

        let reopenableWindowIDs = Set(persistence.reopenableWindowIDs)
        #expect(reopenableWindowIDs == [stored.physicalUUID, added.physicalUUID])
    }
}
