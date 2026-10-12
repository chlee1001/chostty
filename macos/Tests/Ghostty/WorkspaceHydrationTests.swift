import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
@Suite struct WorkspaceHydrationTests {
    @MainActor
    private final class ManualScheduler {
        private(set) var delays: [TimeInterval] = []
        private var actions: [(due: TimeInterval, action: @MainActor () -> Void)] = []
        private(set) var now: TimeInterval = 0

        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            delays.append(delay)
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

        var hasPendingAction: Bool {
            !actions.isEmpty
        }
    }

    private final class BuildCounter {
        var value = 0
    }

    private final class Flag {
        var value = false
    }

    private func tab(_ id: UUID = UUID(), panes: Int = 1) -> TabSnapshot {
        let leaves = (0..<panes).map { _ in
            PaneTreeSnapshot.leaf(PaneLeafSnapshot(uuid: UUID(), cwd: nil, title: nil))
        }
        let tree = leaves.dropFirst().reduce(leaves[0]) { partial, leaf in
            .split(direction: .horizontal, ratio: 0.5, left: partial, right: leaf)
        }
        return TabSnapshot(id: id, titleOverride: nil, tabColor: nil, paneTree: tree, focusedPaneID: nil, zoomedPaneID: nil)
    }

    private func registry(_ scheduler: ManualScheduler, tabs: [TabSnapshot]) -> PendingHydrationRegistry {
        let registry = PendingHydrationRegistry(scheduleAfter: { delay, action in
            scheduler.schedule(delay, action)
        })
        for tab in tabs {
            registry.store(tab, for: tab.id)
        }
        return registry
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-hydration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func inertConstructor(
        count: BuildCounter? = nil,
        fails: Bool = false
    ) -> TerminalControllerGraphFactory.SurfaceConstructor {
        { config, uuid in
            count?.value += 1
            guard !fails,
                  let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }
    }

    private func workspace(_ tabs: [TabSnapshot], id: UUID = UUID()) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id,
            name: "Workspace",
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: tabs,
            selectedTabID: tabs.first?.id
        )
    }

    private func controller(
        workspaces: [WorkspaceSnapshot],
        selectedWorkspace: UUID,
        registry: PendingHydrationRegistry,
        persistence: SessionPersistenceController,
        construct: @escaping TerminalControllerGraphFactory.SurfaceConstructor,
        heldBack: Set<UUID> = []
    ) throws -> TerminalController {
        let selectedTab = try #require(
            workspaces.first { $0.id == selectedWorkspace }?.selectedTabID
        )
        let graph = try #require(TerminalControllerGraphFactory.makeFromSnapshot(
            ghostty: TerminalControllerTestHarness.sharedApp,
            window: WindowSnapshot(
                physicalUUID: UUID(),
                selection: .init(workspaceID: selectedWorkspace, tabID: selectedTab),
                workspaces: workspaces
            ),
            bindings: .init(registry: registry, construct: construct, persistence: persistence),
            heldBackTabIDs: heldBack
        ))
        return TerminalController(TerminalControllerTestHarness.sharedApp, graph: graph)
    }

    private func persistence(
        directory: URL,
        registry: PendingHydrationRegistry,
        scheduler: ManualScheduler,
        live: @escaping @Sendable (Int32) -> Bool = { _ in false },
        uptime: @escaping @Sendable () -> UInt64 = { 100 }
    ) -> SessionPersistenceController {
        SessionPersistenceController(
            repository: SessionSnapshotRepository(directory: directory),
            gate: SessionPersistenceGate(environment: [:], arguments: [], configEnabled: true),
            registry: registry,
            isLiveInstance: live,
            scheduleAfter: { delay, action in scheduler.schedule(delay, action) },
            uptime: uptime,
            controllersProvider: { [] }
        )
    }

    private func session(_ id: UUID, in controller: TerminalController) throws -> TerminalSessionState {
        try #require(controller.workspaceStore.session(forTabID: id))
    }

    @Test func launchHydratesEveryTabOfTheSelectedWorkspaceOneTabPerStep() {
        let scheduler = ManualScheduler()
        let tabs = [tab(), tab(), tab()]
        let registry = registry(scheduler, tabs: tabs)
        let owner = NSObject()
        var hydrated: [UUID] = []
        registry.enqueueHydration(tabs.map(\.id), owner: owner) { id in
            hydrated.append(id)
            _ = registry.take(id)
            return .hydrated(panes: 1)
        }
        scheduler.runNext()
        #expect(hydrated.count == 1)
        scheduler.runNext()
        #expect(hydrated.count == 2)
        scheduler.runNext()
        #expect(hydrated.count == 3)
        #expect(hydrated == tabs.map(\.id))
    }

    @Test func stepDelayScalesWithPanesBuilt() {
        let scheduler = ManualScheduler()
        let tabs = [tab(panes: 3), tab()]
        let registry = registry(scheduler, tabs: tabs)
        let owner = NSObject()
        registry.enqueueHydration(tabs.map(\.id), owner: owner) { id in
            _ = registry.take(id)
            return .hydrated(panes: id == tabs[0].id ? 3 : 1)
        }
        scheduler.runNext()
        #expect(scheduler.delays.last == PendingHydrationRegistry.hydrationStepInterval * 3)
    }

    @Test func skippedEntriesDoNotCostAStep() {
        let scheduler = ManualScheduler()
        let first = tab()
        let second = tab()
        let registry = registry(scheduler, tabs: [first, second])
        let owner = NSObject()
        var hydrated: [UUID] = []
        registry.enqueueHydration([first.id, second.id], owner: owner) { id in
            hydrated.append(id)
            _ = registry.take(id)
            return .hydrated(panes: 1)
        }
        _ = registry.take(first.id)
        scheduler.runNext()
        #expect(hydrated == [second.id])
    }

    @Test func theMostRecentlySelectedWorkspaceJumpsTheQueue() {
        let scheduler = ManualScheduler()
        let first = tab()
        let second = tab()
        let registry = registry(scheduler, tabs: [first, second])
        let owner = NSObject()
        var hydrated: [UUID] = []
        let hydrate: @MainActor (UUID) -> HydrationOutcome = { id in
            hydrated.append(id)
            _ = registry.take(id)
            return .hydrated(panes: 1)
        }
        registry.enqueueHydration([first.id], owner: owner, hydrate: hydrate)
        registry.enqueueHydration([second.id], owner: owner, hydrate: hydrate)
        scheduler.runNext()
        #expect(hydrated == [second.id])
    }

    @Test func aTabSelectedWhileQueuedIsHydratedOnlyOnce() {
        let scheduler = ManualScheduler()
        let tab = tab()
        let registry = registry(scheduler, tabs: [tab])
        let owner = NSObject()
        var calls = 0
        registry.enqueueHydration([tab.id], owner: owner) { id in
            calls += 1
            _ = registry.take(id)
            return .hydrated(panes: 1)
        }
        _ = registry.take(tab.id)
        scheduler.runNext()
        #expect(calls == 0)
    }

    @Test func aTabClosedWhileQueuedIsSkipped() {
        let scheduler = ManualScheduler()
        let tab = tab()
        let registry = registry(scheduler, tabs: [tab])
        let owner = NSObject()
        var calls = 0
        registry.enqueueHydration([tab.id], owner: owner) { _ in
            calls += 1
            return .hydrated(panes: 1)
        }
        _ = registry.take(tab.id)
        scheduler.runNext()
        #expect(calls == 0)
    }

    @Test func cancellingAnOwnerDropsItsQueuedHydration() {
        let scheduler = ManualScheduler()
        let tab = tab()
        let registry = registry(scheduler, tabs: [tab])
        let owner = NSObject()
        var calls = 0
        registry.enqueueHydration([tab.id], owner: owner) { _ in
            calls += 1
            return .hydrated(panes: 1)
        }
        registry.cancelHydration(owner: owner)
        scheduler.runNext()
        #expect(calls == 0)
    }

    @Test func aFailedStepStopsThatWindowsDrainAndKeepsTheRestPending() {
        let scheduler = ManualScheduler()
        let firstOwnerTabs = [tab(), tab()]
        let secondOwnerTab = tab()
        let registry = registry(scheduler, tabs: firstOwnerTabs + [secondOwnerTab])
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        var failedCalls = 0
        var succeedingCalls = 0
        // The other window's work is queued first; the failing window's
        // enqueue jumps ahead of it.
        registry.enqueueHydration([secondOwnerTab.id], owner: secondOwner) { id in
            succeedingCalls += 1
            _ = registry.take(id)
            return .hydrated(panes: 1)
        }
        registry.enqueueHydration(firstOwnerTabs.map(\.id), owner: firstOwner) { _ in
            failedCalls += 1
            return .failed
        }
        scheduler.runNext()
        #expect(failedCalls == 1)
        #expect(succeedingCalls == 0)
        #expect(registry.contains(firstOwnerTabs[1].id))
        scheduler.runNext()
        #expect(failedCalls == 1)
        #expect(succeedingCalls == 1)
    }

    @Test func tabsOfNeverVisitedWorkspacesStayPending() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let directory = try directory()
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let first = tab()
        let deferred = tab()
        let firstWorkspace = workspace([first])
        let secondWorkspace = workspace([deferred])
        let controller = try controller(
            workspaces: [firstWorkspace, secondWorkspace],
            selectedWorkspace: firstWorkspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor()
        )

        controller.scheduleWorkspaceHydration(workspaceID: firstWorkspace.id)
        scheduler.runNext()

        #expect(registry.contains(deferred.id))
        #expect(try session(deferred.id, in: controller).surfaceTree.isEmpty)
    }

    @Test func selectingATabInAnotherWorkspaceHydratesItNowAndQueuesTheRestOfThatWorkspace() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let persistence = persistence(directory: try directory(), registry: registry, scheduler: scheduler)
        let first = tab()
        let selected = tab()
        let queued = tab()
        let firstWorkspace = workspace([first])
        let secondWorkspace = workspace([selected, queued])
        let controller = try controller(
            workspaces: [firstWorkspace, secondWorkspace],
            selectedWorkspace: firstWorkspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor()
        )

        controller.selectSession(workspaceID: secondWorkspace.id, tabID: selected.id)

        #expect(!registry.contains(selected.id))
        #expect(registry.contains(queued.id))
        scheduler.runNext()
        #expect(!registry.contains(queued.id))
    }

    @Test func backgroundHydratedPanesAreReportedHidden() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let persistence = persistence(directory: try directory(), registry: registry, scheduler: scheduler)
        let selected = tab()
        let background = tab()
        let workspace = workspace([selected, background])
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor()
        )

        controller.scheduleWorkspaceHydration(workspaceID: workspace.id)
        scheduler.runNext()
        let pane = try #require(session(background.id, in: controller).surfaceTree.first)
        #expect(controller.surfaceVisibility(windowVisible: true)[pane.id] == false)
    }

    @Test func aTabThatDiedDuringPacedHydrationIsNotAutoHydratedAgain() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        var ownerIsLive = true
        let persistence = persistence(
            directory: directory,
            registry: registry,
            scheduler: scheduler,
            live: { _ in ownerIsLive }
        )
        let initial = tab()
        let pending = (0..<16).map { _ in tab() }
        let workspace = workspace([initial] + pending)
        let builds = BuildCounter()
        let construct: TerminalControllerGraphFactory.SurfaceConstructor = { config, uuid in
            builds.value += 1
            if builds.value == 17 {
                ownerIsLive = false
            }
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: construct
        )
        controller.scheduleWorkspaceHydration(workspaceID: workspace.id)
        var firstDrainSteps = 0
        while builds.value < 17 {
            guard scheduler.hasPendingAction else {
                _ = try #require(false)
                return
            }
            guard firstDrainSteps < 20 else {
                _ = try #require(false)
                return
            }
            scheduler.runNext()
            firstDrainSteps += 1
        }
        let crashedTab = try #require(pending.last)

        let nextScheduler = ManualScheduler()
        let nextRegistry = PendingHydrationRegistry(scheduleAfter: nextScheduler.schedule)
        let nextBuilds = BuildCounter()
        let nextPersistence = self.persistence(
            directory: directory,
            registry: nextRegistry,
            scheduler: nextScheduler,
            live: { _ in false }
        )
        let restored = try self.controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: nextRegistry,
            persistence: nextPersistence,
            construct: inertConstructor(count: nextBuilds),
            heldBack: nextPersistence.restoreQuarantine().tabs
        )
        // The crashed tab, and every tab whose success had not settled yet
        // when the process died, comes back held back.
        let heldBack = nextPersistence.restoreQuarantine().tabs
        #expect(heldBack.contains(crashedTab.id))
        #expect(heldBack.count < pending.count)
        let pendingSession = try session(crashedTab.id, in: restored)
        restored.scheduleWorkspaceHydration(workspaceID: workspace.id)

        #expect(pendingSession.isHeldBack)
        #expect(pendingSession.surfaceTree.isEmpty)
        #expect(nextRegistry.contains(crashedTab.id))
        var drainSteps = 0
        while nextScheduler.hasPendingAction {
            guard drainSteps < 60 else {
                _ = try #require(false)
                return
            }
            nextScheduler.runNext()
            drainSteps += 1
        }
        var settledTabsBuilt = true
        var heldBackTabsUnbuilt = true
        for tab in pending {
            let restoredSession = try session(tab.id, in: restored)
            if heldBack.contains(tab.id) {
                heldBackTabsUnbuilt = heldBackTabsUnbuilt
                    && restoredSession.isHeldBack
                    && restoredSession.surfaceTree.isEmpty
                    && nextRegistry.contains(tab.id)
            } else {
                settledTabsBuilt = settledTabsBuilt && !restoredSession.surfaceTree.isEmpty
            }
        }
        #expect(settledTabsBuilt)
        #expect(heldBackTabsUnbuilt)
    }

    @Test func aHeldBackSelectedTabIsNotBuiltAtBoot() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let selected = tab()
        let workspace = workspace([selected])
        let builds = BuildCounter()
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence(directory: try directory(), registry: registry, scheduler: scheduler),
            construct: inertConstructor(count: builds),
            heldBack: [selected.id]
        )

        #expect(builds.value == 0)
        #expect(try session(selected.id, in: controller).isHeldBack)
        #expect(registry.contains(selected.id))
    }

    @Test func heldBackBootSelectedTabKeepsItsWindowAndTabs() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let selected = tab()
        let sibling = tab()
        let workspace = workspace([selected, sibling])
        let persistence = self.persistence(
            directory: try directory(),
            registry: registry,
            scheduler: scheduler
        )
        let graph = try #require(TerminalControllerGraphFactory.makeFromSnapshot(
            ghostty: TerminalControllerTestHarness.sharedApp,
            window: WindowSnapshot(
                physicalUUID: UUID(),
                selection: .init(workspaceID: workspace.id, tabID: selected.id),
                workspaces: [workspace]
            ),
            bindings: .init(registry: registry, construct: inertConstructor(), persistence: persistence),
            heldBackTabIDs: [selected.id]
        ))
        let closeCount = BuildCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { _ in
            closeCount.value += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let controller = TerminalController(TerminalControllerTestHarness.sharedApp, graph: graph)

        #expect(controller.window != nil)
        #expect(closeCount.value == 0)
        #expect(controller.workspaceStore.allSessions.count == 2)
        #expect(try session(selected.id, in: controller).surfaceTree.isEmpty)
        #expect(try session(selected.id, in: controller).isHeldBack)
    }

    @Test func selectingAHeldBackTabHydratesItAndLiftsTheHoldAfterTheSettle() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let selected = tab()
        let workspace = workspace([selected])
        let persistence = persistence(directory: try directory(), registry: registry, scheduler: scheduler)
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor(),
            heldBack: [selected.id]
        )
        let held = try session(selected.id, in: controller)

        controller.selectSession(workspaceID: workspace.id, tabID: selected.id)
        #expect(held.isHeldBack)
        // The selection also schedules a debounced save on the same scheduler;
        // run due actions until the settle has fired.
        for _ in 0..<10 where held.isHeldBack && scheduler.hasPendingAction {
            scheduler.runNext()
        }
        #expect(!held.isHeldBack)
    }

    @Test func failedRetryKeepsThePreviousCrashHoldAcrossRelaunch() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let tab = tab()
        try SessionSnapshotRepository(directory: directory).updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: tab.id, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 9, startedAtUptime: 1))
        }
        let workspace = workspace([tab])
        let failedBuilds = BuildCounter()
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor(count: failedBuilds, fails: true),
            heldBack: persistence.restoreQuarantine().tabs
        )

        controller.selectSession(workspaceID: workspace.id, tabID: tab.id)
        #expect(try session(tab.id, in: controller).hydrationFailed)
        #expect(failedBuilds.value > 0)

        let nextScheduler = ManualScheduler()
        let nextRegistry = PendingHydrationRegistry(scheduleAfter: nextScheduler.schedule)
        let next = self.persistence(directory: directory, registry: nextRegistry, scheduler: nextScheduler)
        #expect(next.restoreQuarantine().tabs.contains(tab.id))
        let nextBuilds = BuildCounter()
        let restored = try self.controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: nextRegistry,
            persistence: next,
            construct: inertConstructor(count: nextBuilds),
            heldBack: next.restoreQuarantine().tabs
        )
        restored.scheduleWorkspaceHydration(workspaceID: workspace.id)
        while nextScheduler.hasPendingAction {
            nextScheduler.runNext()
        }
        #expect(try session(tab.id, in: restored).isHeldBack)
        #expect(nextBuilds.value == 0)
    }

    @Test func noOpSelectionDoesNotClearADeadAttempt() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let firstView = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let secondView = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let first = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: firstView))
        let second = TerminalSessionState(id: UUID(), surfaceTree: SplitTree(view: secondView))
        let workspaceID = UUID()
        let liveWorkspace = WorkspaceSession(
            id: workspaceID,
            name: "Workspace",
            tabs: [first, second],
            selectedTabID: first.id
        )
        let repository = SessionSnapshotRepository(directory: directory)
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: first.id, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 9, startedAtUptime: 1))
        }
        let before = try Data(contentsOf: repository.restoreAttemptsURL)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [liveWorkspace],
            selection: Selection(workspaceID: workspaceID, tabID: first.id)
        ))
        controller.injectRestoreBindings(.init(registry: registry, construct: inertConstructor(), persistence: persistence))
        controller.selectSession(workspaceID: workspaceID, tabID: first.id)
        controller.selectSession(workspaceID: workspaceID, tabID: second.id)
        controller.selectSession(workspaceID: workspaceID, tabID: first.id)
        #expect(try Data(contentsOf: repository.restoreAttemptsURL) == before)
    }

    @Test func selectingALiveTabNeverTouchesTheAttemptsLedger() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let selected = tab()
        let workspace = workspace([selected])
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence(directory: directory, registry: registry, scheduler: scheduler),
            construct: inertConstructor()
        )
        controller.selectSession(workspaceID: workspace.id, tabID: selected.id)
        #expect(!FileManager.default.fileExists(atPath: SessionSnapshotRepository(directory: directory).restoreAttemptsURL.path))
    }

    @Test func detachingAPendingTabRecordsItsConstructionAttempt() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let repository = SessionSnapshotRepository(directory: directory)
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let live = tab()
        let pending = tab()
        let workspace = workspace([live, pending])
        let observedAttempt = Flag()
        let construct: TerminalControllerGraphFactory.SurfaceConstructor = { config, uuid in
            observedAttempt.value = repository.restoreAttempts().contains { attempt in
                attempt.kind == .tab && attempt.targetID == pending.id
            }
            guard let app = TerminalControllerTestHarness.sharedApp.app else { return nil }
            return Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid, spawnsSurface: false)
        }
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: construct
        )

        _ = controller.detachTabToNewWindow(tabID: pending.id, screenPoint: nil)

        #expect(observedAttempt.value)
    }

    @Test func detachingAHeldBackTabMovesItPendingWithoutConstructing() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let pending = tab()
        let live = tab()
        let workspace = workspace([live, pending])
        let counter = BuildCounter()
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence(directory: try directory(), registry: registry, scheduler: scheduler),
            construct: inertConstructor(count: counter),
            heldBack: [pending.id]
        )

        let destination = controller.detachTabToNewWindow(tabID: pending.id, screenPoint: nil)
        let moved = try #require(destination?.workspaceStore.session(forTabID: pending.id))

        #expect(counter.value == 1)
        #expect(moved.surfaceTree.isEmpty)
        #expect(moved.isHeldBack)
        #expect(registry.contains(pending.id))
    }

    @Test func anUnrecordedAutomaticStepNeverConstructs() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName),
            withIntermediateDirectories: true
        )
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let selected = tab()
        let firstPending = tab()
        let secondPending = tab()
        let workspace = workspace([selected, firstPending, secondPending])
        let counter = BuildCounter()
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor(count: counter)
        )
        let firstPendingSession = try session(firstPending.id, in: controller)
        let secondPendingSession = try session(secondPending.id, in: controller)
        let buildsAtBoot = counter.value

        controller.scheduleWorkspaceHydration(workspaceID: workspace.id)
        scheduler.runNext()

        #expect(counter.value == buildsAtBoot)
        #expect(firstPendingSession.surfaceTree.isEmpty)
        #expect(secondPendingSession.surfaceTree.isEmpty)
        #expect(registry.contains(firstPending.id))
        #expect(registry.contains(secondPending.id))
        #expect(persistence.restoreAttemptsUnavailable)
        #expect(persistence.restoreAttemptStarts == 1)
    }

    @Test func automaticHydrationResumesOnceTheAttemptCanBeRecorded() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let lockURL = directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let selected = tab()
        let first = tab()
        let second = tab()
        let workspace = workspace([selected, first, second])
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor()
        )
        controller.scheduleWorkspaceHydration(workspaceID: workspace.id)
        scheduler.runNext()
        try FileManager.default.removeItem(at: lockURL)

        controller.selectSession(workspaceID: workspace.id, tabID: first.id)
        scheduler.runNext()
        scheduler.runNext()

        #expect(!registry.contains(first.id))
        #expect(!registry.contains(second.id))
        #expect(!persistence.restoreAttemptsUnavailable)
    }

    @Test func explicitSelectionOpensATabEvenWhenTheAttemptCannotBeRecorded() throws {
        let scheduler = ManualScheduler()
        let directory = try directory()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName),
            withIntermediateDirectories: true
        )
        let persistence = persistence(directory: directory, registry: registry, scheduler: scheduler)
        let live = tab()
        let pending = tab()
        let workspace = workspace([live, pending])
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor()
        )

        controller.selectSession(workspaceID: workspace.id, tabID: pending.id)

        #expect(!registry.contains(pending.id))
        #expect(!(try session(pending.id, in: controller).surfaceTree.isEmpty))
        #expect(persistence.restoreAttemptsUnavailable)
    }

    @Test func aFailedHydrationMarksTheTabUntilItSucceeds() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let live = tab()
        let pending = tab()
        let workspace = workspace([live, pending])
        let persistence = persistence(directory: try directory(), registry: registry, scheduler: scheduler)
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor(fails: true)
        )
        let state = try session(pending.id, in: controller)
        let window = try #require(controller.window)
        let closed = Flag()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in
            closed.value = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.selectSession(workspaceID: workspace.id, tabID: pending.id)
        #expect(state.hydrationFailed)
        #expect(!closed.value)
        #expect(controller.workspaceStore.allSessions.count == 2)
        controller.injectRestoreBindings(.init(registry: registry, construct: inertConstructor(), persistence: persistence))
        controller.selectSession(workspaceID: workspace.id, tabID: pending.id)
        #expect(!state.hydrationFailed)
    }

    @Test func cancelledTerminationResumesTheSelectedWorkspaceDrain() throws {
        let scheduler = ManualScheduler()
        let registry = PendingHydrationRegistry(scheduleAfter: scheduler.schedule)
        let selected = tab()
        let pending = tab()
        let workspace = workspace([selected, pending])
        let persistence = persistence(directory: try directory(), registry: registry, scheduler: scheduler)
        let controller = try controller(
            workspaces: [workspace],
            selectedWorkspace: workspace.id,
            registry: registry,
            persistence: persistence,
            construct: inertConstructor()
        )

        controller.scheduleWorkspaceHydration(workspaceID: workspace.id)
        registry.cancelAllHydration()
        controller.scheduleWorkspaceHydration(
            workspaceID: controller.workspaceStore.snapshot.selection.workspaceID
        )
        scheduler.runNext()

        #expect(!registry.contains(pending.id))
        #expect(!(try session(pending.id, in: controller).surfaceTree.isEmpty))
    }
}
