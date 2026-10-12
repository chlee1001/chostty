import Foundation
import Testing
@testable import Ghostty

@MainActor
@Suite struct DormantWindowTests {
    @MainActor
    private final class ManualScheduler {
        private var actions: [(due: TimeInterval, action: @MainActor () -> Void)] = []
        private(set) var now: TimeInterval = 0

        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            actions.append((due: now + delay, action: action))
        }

        func runNext() {
            guard let index = actions.indices.min(by: { actions[$0].due < actions[$1].due }) else {
                return
            }
            let next = actions.remove(at: index)
            now = next.due
            next.action()
        }

        func runAll() {
            while !actions.isEmpty {
                runNext()
            }
        }
    }

    private final class Counter {
        var value = 0
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dormant-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func tab(cwd: String, id: UUID = UUID(), leafID: UUID = UUID()) -> TabSnapshot {
        TabSnapshot(
            id: id,
            titleOverride: nil,
            tabColor: nil,
            paneTree: .leaf(PaneLeafSnapshot(uuid: leafID, cwd: cwd, title: nil)),
            focusedPaneID: leafID,
            zoomedPaneID: nil
        )
    }

    private func window(
        cwd: String,
        id: UUID = UUID(),
        workspaceName: String = "Workspace",
        tabID: UUID = UUID(),
        leafID: UUID = UUID()
    ) -> WindowSnapshot {
        let tab = tab(cwd: cwd, id: tabID, leafID: leafID)
        let workspace = WorkspaceSnapshot(
            id: UUID(),
            name: workspaceName,
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: [tab],
            selectedTabID: tab.id
        )
        return WindowSnapshot(
            physicalUUID: id,
            selection: .init(workspaceID: workspace.id, tabID: tab.id),
            workspaces: [workspace]
        )
    }

    private func snapshot(_ windows: [WindowSnapshot]) -> AppSessionSnapshot {
        AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 1, windows: windows)
    }

    private func unbuildableWindow(id: UUID) -> WindowSnapshot {
        WindowSnapshot(physicalUUID: id, selection: nil, workspaces: [])
    }

    private func seed(_ repository: SessionSnapshotRepository, windows: [WindowSnapshot]) throws {
        _ = try repository.save(snapshot(windows), policy: .init(
            claimEpoch: 1,
            selfInstanceID: UUID(),
            selfPID: 1,
            deferredOwnerIDs: [],
            isLiveInstance: { _ in false },
            now: { 1 },
            retire: []
        ))
    }

    private func persistence(
        repository: SessionSnapshotRepository,
        registry: PendingHydrationRegistry,
        scheduler: ManualScheduler,
        otherInstanceRunning: @escaping () -> Bool = { false }
    ) -> SessionPersistenceController {
        SessionPersistenceController(
            repository: repository,
            gate: SessionPersistenceGate(environment: [:], arguments: [], configEnabled: true),
            registry: registry,
            isLiveInstance: { _ in false },
            otherInstanceRunning: otherInstanceRunning,
            scheduleAfter: { delay, action in scheduler.schedule(delay, action) },
            controllersProvider: { [] }
        )
    }

    private func inertConstructor(
        count: Counter? = nil
    ) -> TerminalControllerGraphFactory.SurfaceConstructor {
        { config, uuid in
            count?.value += 1
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }
    }

    private func promote(
        _ windows: [WindowSnapshot],
        persistence: SessionPersistenceController,
        registry: PendingHydrationRegistry,
        construct: @escaping TerminalControllerGraphFactory.SurfaceConstructor,
        trigger: TerminalController.PromotionTrigger = .userReopen,
        heldBackTabIDs: Set<UUID> = []
    ) -> [TerminalController] {
        TerminalController.promoteStoredWindows(
            windows,
            ghostty: TerminalControllerTestHarness.sharedApp,
            bindings: .init(registry: registry, construct: construct, persistence: persistence),
            heldBackTabIDs: heldBackTabIDs,
            trigger: trigger,
            present: { _ in }
        )
    }

    @Test func promotionBuildsTheStoredWindowAndClaimsIt() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        persistence.storeDormant([stored.physicalUUID])

        let built = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor())

        #expect(built.count == 1)
        #expect(built[0].physicalUUID == stored.physicalUUID)
        #expect(persistence.claimedWindowIDs.contains(stored.physicalUUID))
        #expect(!persistence.dormantWindowIDs.contains(stored.physicalUUID))
    }

    @Test func aWindowThatFailsToBuildStaysDormantAndInTheFile() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        persistence.storeDormant([stored.physicalUUID])

        let built = promote(
            [unbuildableWindow(id: stored.physicalUUID)],
            persistence: persistence,
            registry: registry,
            construct: inertConstructor()
        )
        let loaded = repository.load()

        #expect(built.isEmpty)
        #expect(persistence.dormantWindowIDs == [stored.physicalUUID])
        if case .loaded(let saved, _) = loaded {
            #expect(saved.windows == [stored])
        } else {
            Issue.record("Expected the stored window to remain in the session file")
        }
    }

    @Test func aWindowThatFailsToBuildKeepsItsEarlierCrashHold() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .window, targetID: stored.physicalUUID, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 1))
        }

        _ = promote(
            [unbuildableWindow(id: stored.physicalUUID)],
            persistence: persistence,
            registry: registry,
            construct: inertConstructor()
        )
        scheduler.runAll()

        #expect(persistence.restoreQuarantine().windows.contains(stored.physicalUUID))
    }

    @Test func windowsAreQuarantinedWhileTheyAreBeingBuilt() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        let sawQuarantine = Counter()
        let construct: TerminalControllerGraphFactory.SurfaceConstructor = { config, uuid in
            let recorded = repository.restoreAttempts().contains { attempt in
                attempt.kind == .window && attempt.targetID == stored.physicalUUID
            }
            if recorded {
                sawQuarantine.value += 1
            }
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }

        _ = promote([stored], persistence: persistence, registry: registry, construct: construct)

        #expect(sawQuarantine.value > 0)
    }

    @Test func quarantineLiftsAfterTheSettleDelay() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)

        let isRecorded = {
            repository.restoreAttempts().contains { attempt in
                attempt.kind == .window && attempt.targetID == stored.physicalUUID
            }
        }

        _ = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor())
        let recordedBeforeSettle = isRecorded()
        #expect(recordedBeforeSettle)
        scheduler.runAll()
        let recordedAfterSettle = isRecorded()
        #expect(!recordedAfterSettle)
    }

    @Test func automaticPromotionBuildsNothingWhenTheAttemptCannotBeRecorded() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let original = try Data(contentsOf: repository.primaryURL)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName),
            withIntermediateDirectories: true
        )
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        persistence.storeDormant([stored.physicalUUID])
        let builds = Counter()

        let boot = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor(count: builds), trigger: .boot)
        let dock = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor(count: builds), trigger: .dockReopen)

        #expect(boot.isEmpty)
        #expect(dock.isEmpty)
        #expect(builds.value == 0)
        #expect(persistence.dormantWindowIDs == [stored.physicalUUID])
        let after = try Data(contentsOf: repository.primaryURL)
        #expect(after == original)
    }

    @Test func userReopenProceedsWhenTheAttemptCannotBeRecorded() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName),
            withIntermediateDirectories: true
        )
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)

        let built = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor())

        #expect(built.count == 1)
    }

    @Test func promotedWindowHydratesThroughItsInjectedBindingsOnly() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let first = window(cwd: directory.path)
        let second = window(cwd: directory.path)
        try seed(repository, windows: [first, second])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        let builds = Counter()
        let failedTabID = first.workspaces[0].tabs[0].id
        let failedLeafID = try #require(first.workspaces[0].tabs[0].paneTree?.leaves.first?.uuid)
        let construct: TerminalControllerGraphFactory.SurfaceConstructor = { config, uuid in
            builds.value += 1
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
            if uuid == failedLeafID {
                view.error = Ghostty.Error.apiFailed
            }
            return view
        }

        let controllers = promote(
            [first, second],
            persistence: persistence,
            registry: registry,
            construct: construct
        )
        scheduler.runAll()

        #expect(controllers.count == 2)
        #expect(builds.value >= 2)
        #expect(registry.contains(failedTabID))
        for controller in controllers {
            #expect(controller.workspaceStore.snapshot.workspaces.count == 1)
            #expect(controller.surfaceTree.allSatisfy { $0.surface == nil })
            for session in controller.workspaceStore.allSessions {
                #expect(session.surfaceTree.allSatisfy { $0.surface == nil })
            }
        }
    }

    @Test func promotionQueuesHydrationOfTheSelectedWorkspace() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let first = tab(cwd: directory.path)
        let second = tab(cwd: directory.path)
        let workspace = WorkspaceSnapshot(id: UUID(), name: "Workspace", color: .none, isCollapsed: false, defaultDirectory: nil, tabs: [first, second], selectedTabID: first.id)
        let stored = WindowSnapshot(physicalUUID: UUID(), selection: .init(workspaceID: workspace.id, tabID: first.id), workspaces: [workspace])
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)

        _ = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor())

        #expect(registry.contains(second.id))
    }

    @Test func promotedWindowKeepsItsRecordedIdentity() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let identifier = UUID()
        let stored = window(cwd: directory.path, id: identifier)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)

        let built = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor())

        #expect(built.first?.physicalUUID == identifier)
    }

    @Test func promotedHeldBackTabStaysPending() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let tabID = UUID()
        let stored = window(cwd: directory.path, tabID: tabID)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)

        let built = promote([stored], persistence: persistence, registry: registry, construct: inertConstructor(), heldBackTabIDs: [tabID])
        let controller = try #require(built.first)
        let session = try #require(controller.workspaceStore.session(forTabID: tabID))

        #expect(session.isHeldBack)
        #expect(session.surfaceTree.isEmpty)
        #expect(registry.contains(tabID))
    }

    @Test func dockReopenCandidatesExcludeQuarantinedWindows() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let stored = window(cwd: directory.path)
        try seed(repository, windows: [stored])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        persistence.storeDormant([stored.physicalUUID])
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .window, targetID: stored.physicalUUID, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 1))
        }

        #expect(persistence.dockReopenCandidateIDs.isEmpty)
    }

    @Test func reopenReadsTheLatestStoredVersionOfAWindow() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let identifier = UUID()
        let initial = window(cwd: directory.path, id: identifier, workspaceName: "Initial")
        let latest = window(cwd: directory.path, id: identifier, workspaceName: "Latest")
        try seed(repository, windows: [initial])
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        persistence.storeDormant([identifier])
        try seed(repository, windows: [latest])

        let windows = persistence.storedWindows(matching: [identifier])

        #expect(windows == [latest])
    }

    @Test func dormantWindowsDidChangePostsOnlyWhenTheListChanges() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let persistence = persistence(repository: repository, registry: registry, scheduler: scheduler)
        let identifier = UUID()
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SessionPersistenceController.dormantWindowsDidChange,
            object: persistence,
            queue: .main
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        persistence.storeDormant([identifier])
        persistence.storeDormant([identifier])
        persistence.claimDormant(identifier)
        persistence.claimDormant(identifier)

        #expect(notifications == 2)
    }
}
