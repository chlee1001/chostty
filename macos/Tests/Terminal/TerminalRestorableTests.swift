import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite
struct TerminalRestorableTests {
    private enum InjectedFailure: Error { case factory }

    /// libghostty cannot create a surface when the host has no attached
    /// display (locked screen, headless runner) and reports that as
    /// `surfaceCreationFailed`. The live-surface cases below degrade the same
    /// way the rest of the suite does with `TerminalControllerTestHarness`:
    /// skip the body instead of reporting a false product failure.
    @MainActor
    private func coldSurface(
        _ ghostty: Ghostty.App,
        logicalPaneID: UUID = UUID()
    ) throws -> Ghostty.SurfaceView? {
        guard let app = ghostty.app else { return nil }
        do {
            return try Ghostty.SurfaceView.makeColdRestored(
                app,
                logicalPaneID: logicalPaneID)
        } catch Ghostty.SurfaceView.ColdRestoreError.surfaceCreationFailed {
            return nil
        }
    }
    private let physicalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let workspaceID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let tabID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let paneID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!

    @Test func versionsPinCleanOrdinaryV9AndQuickTerminalV1() {
        #expect(TerminalRestorableState.version == 9)
        #expect(TerminalRestorableState.minimumVersion == 9)
        #expect(QuickTerminalRestorableState.version == 1)
        #expect(QuickTerminalRestorableState.minimumVersion == 1)
    }

    @Test func validV9RoundTripProducesRestorePlan() throws {
        let state = try state(from: wire())
        let decoded = try decodeOuter(try encodeOuter(state))
        let plan = try decoded.restorePlan()

        #expect(plan.snapshot.physicalWindowID == physicalID)
        #expect(plan.snapshot.workspaces[0].id == workspaceID)
        #expect(plan.snapshot.workspaces[0].tabs[0].id == tabID)
        #expect(plan.snapshot.workspaces[0].tabs[0].tree.nodes == [
            .pane(.init(logicalPaneID: paneID, currentWorkingDirectory: "/tmp", rawTitle: "", hasUserTitle: false))
        ])
    }

    @Test func lowerAndFutureVersionsRejectBeforeStateDecode() throws {
        for version in [8, 10] {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            archiver.encode(version, forKey: TerminalRestorableState.versionKey)
            // Deliberately incompatible poison: accepted versions would attempt secure state decoding.
            archiver.encode("poison" as NSString, forKey: TerminalRestorableState.selfKey)

            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
            defer { unarchiver.finishDecoding() }
            #expect(TerminalRestorableState(coder: unarchiver) == nil)
        }
    }

    @Test @MainActor func v8EntryPointRejectsBeforeInjectedPaneFactory() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(delegate.ghostty.config.windowSaveState != "never")
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(8, forKey: TerminalRestorableState.versionKey)
        archiver.encode(
            "poison" as NSString,
            forKey: TerminalRestorableState.selfKey)
        let state = try NSKeyedUnarchiver(
            forReadingFrom: archiver.encodedData)
        defer { state.finishDecoding() }
        var factoryCalls = 0
        var completionCalls = 0
        TerminalWindowRestoration.paneFactoryOverride = { _, _ in
            factoryCalls += 1
            throw InjectedFailure.factory
        }
        defer { TerminalWindowRestoration.paneFactoryOverride = nil }

        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(
                describing: TerminalWindowRestoration.self)),
            state: state
        ) { window, _ in
            completionCalls += 1
            #expect(window == nil)
        }

        #expect(factoryCalls == 0)
        #expect(completionCalls == 1)
    }

    @Test func corruptAndOversizedPayloadRejectWithoutAPlan() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(TerminalRestorableState.version, forKey: TerminalRestorableState.versionKey)
        archiver.encode("corrupt" as NSString, forKey: TerminalRestorableState.selfKey)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        #expect(TerminalRestorableState(coder: unarchiver) == nil)

        let oversized = Data(repeating: 0, count: TerminalRestoreLimits.payloadBytes + 1)
        #expect(throws: RestoreDecodeFailure.payloadOversized) {
            try TerminalRestoreWireSnapshot.decodePayload(oversized) { _ in wire() }
        }
    }

    @Test func malformedEmptyDuplicateAndRatioCasesStayInPurePipeline() throws {
        var malformed = wire()
        malformed.workspaces![0].tabs![0].tree!.nodes![0].pane!.logicalPaneID = "bad-id"
        #expect(throws: RestoreSchemaFailure.identifierMalformed(kind: "logicalPane", path: "workspaces[0].tabs[0].tree.nodes[0].pane.logicalPaneID")) {
            try TerminalRestoreSchemaDecoder.convert(malformed)
        }

        var snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces = []
        #expect(throws: RestoreValidationFailure.invariant(path: "workspaces")) {
            try TerminalRestoreValidator.validate(snapshot)
        }

        snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces.append(snapshot.workspaces[0])
        #expect(throws: RestoreValidationFailure.duplicateIdentifier(path: "workspaces[1].id")) {
            try TerminalRestoreValidator.validate(snapshot)
        }

        snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces[0].tabs[0].tree.nodes = [
            .split(direction: .horizontal, ratio: 1, first: 1, second: 2),
            .pane(.init(logicalPaneID: paneID, currentWorkingDirectory: nil, rawTitle: "", hasUserTitle: false)),
            .pane(.init(logicalPaneID: UUID(), currentWorkingDirectory: nil, rawTitle: "", hasUserTitle: false)),
        ]
        #expect(throws: RestoreValidationFailure.invalidValue(path: "workspaces[0].tabs[0].tree.nodes[0].ratio")) {
            try TerminalRestoreValidator.validate(snapshot)
        }
    }

    @Test func boundInvalidArchiveNeverInvokesMaterializationFactory() throws {
        var invalid = wire()
        invalid.workspaces![0].tabs![0].tree!.nodes![0].pane!
            .currentWorkingDirectory = String(
                repeating: "x",
                count: TerminalRestoreLimits.pathBytes + 1)
        let state = try state(from: invalid)
        var factoryCalls = 0

        #expect(throws: RestoreDecodeFailure.budgetExceeded(
            path: "workspaces[0].tabs[0].tree.nodes[0].pane.currentWorkingDirectory")) {
            try state.withValidatedPlan { _ in
                factoryCalls += 1
            }
        }
        #expect(factoryCalls == 0)
    }

    @Test func aggregateBudgetsRejectDuringWireDecoding() throws {
        var tabOverflow = wire()
        let tab = tabOverflow.workspaces![0].tabs![0]
        tabOverflow.workspaces![0].tabs = Array(
            repeating: tab,
            count: TerminalRestoreLimits.tabsPerWindow + 1)
        let tabData = try JSONEncoder().encode(tabOverflow)
        #expect(throws: RestoreDecodeFailure.budgetExceeded(path: "tabs")) {
            try JSONDecoder().decode(
                TerminalRestoreWireSnapshot.self,
                from: tabData)
        }

        var paneOverflow = wire()
        var paneTab = tab
        paneTab.tree!.nodes = Array(
            repeating: paneTab.tree!.nodes![0],
            count: TerminalRestoreLimits.panesPerTab)
        paneOverflow.workspaces![0].tabs = Array(
            repeating: paneTab,
            count: TerminalRestoreLimits.panesPerWindow /
                TerminalRestoreLimits.panesPerTab + 1)
        let paneData = try JSONEncoder().encode(paneOverflow)
        #expect(throws: RestoreDecodeFailure.budgetExceeded(path: "panes")) {
            try JSONDecoder().decode(
                TerminalRestoreWireSnapshot.self,
                from: paneData)
        }
    }

    @Test @MainActor func injectedFactoryIsCalledOncePerAcceptedPane() throws {
        let ghostty = TerminalControllerTestHarness.sharedApp
        _ = try #require(ghostty.app)
        guard let probe = try coldSurface(ghostty) else { return }
        probe.surfaceModel?.close()
        let plan = try state(from: wire()).restorePlan()
        var calls = 0
        var requestDirectory: String?
        let transaction = try TerminalRestoreMaterializer.materialize(
            plan,
            ghostty: ghostty
        ) { app, request in
            calls += 1
            requestDirectory = request.currentWorkingDirectory
            return try Ghostty.SurfaceView.makeColdRestored(
                app,
                logicalPaneID: request.logicalPaneID,
                baseConfig: {
                    var config = Ghostty.SurfaceConfiguration()
                    config.workingDirectory = request.currentWorkingDirectory
                    return config
                }())
        }

        #expect(calls == 1)
        #expect(requestDirectory == "/tmp")
        #expect(!transaction.materializationWarnings.contains(
            .currentWorkingDirectoryFallback))
        #expect(transaction.rollback())
    }

    @Test @MainActor func missingCwdFallsBackWithDurableWarning() throws {
        let ghostty = TerminalControllerTestHarness.sharedApp
        _ = try #require(ghostty.app)
        guard let probe = try coldSurface(ghostty) else { return }
        probe.surfaceModel?.close()
        var missing = wire()
        missing.workspaces![0].tabs![0].tree!.nodes![0].pane!
            .currentWorkingDirectory =
            "/path/that/does/not/exist/program-r"
        var requestDirectory: String?
        let transaction = try TerminalRestoreMaterializer.materialize(
            try state(from: missing).restorePlan(),
            ghostty: ghostty
        ) { app, request in
            requestDirectory = request.currentWorkingDirectory
            return try Ghostty.SurfaceView.makeColdRestored(
                app,
                logicalPaneID: request.logicalPaneID)
        }

        #expect(requestDirectory == nil)
        #expect(transaction.materializationWarnings.contains(
            .currentWorkingDirectoryFallback))
        #expect(transaction.rollback())
    }

    @Test @MainActor func nthFactoryFailureSynchronouslyClosesEarlierPanes() throws {
        let ghostty = TerminalControllerTestHarness.sharedApp
        _ = try #require(ghostty.app)
        guard let probe = try coldSurface(ghostty) else { return }
        probe.surfaceModel?.close()
        var twoPane = wire()
        let secondPaneID = UUID()
        twoPane.workspaces![0].tabs![0].tree = .init(
            rootIndex: 0,
            zoomedPaneID: nil,
            nodes: [
                .init(
                    kind: "split",
                    pane: nil,
                    direction: "horizontal",
                    ratio: 0.5,
                    first: 1,
                    second: 2),
                twoPane.workspaces![0].tabs![0].tree!.nodes![0],
                .init(
                    kind: "pane",
                    pane: .init(
                        logicalPaneID: secondPaneID.uuidString,
                        currentWorkingDirectory: "/tmp",
                        rawTitle: "",
                        hasUserTitle: false),
                    direction: nil,
                    ratio: nil,
                    first: nil,
                    second: nil),
            ])
        let plan = try state(from: twoPane).restorePlan()
        var calls = 0
        var firstModel: Ghostty.Surface?

        #expect(throws: InjectedFailure.factory) {
            try TerminalRestoreMaterializer.materialize(
                plan,
                ghostty: ghostty
            ) { app, request in
                calls += 1
                if calls == 2 { throw InjectedFailure.factory }
                let view = try Ghostty.SurfaceView.makeColdRestored(
                    app,
                    logicalPaneID: request.logicalPaneID)
                firstModel = view.surfaceModel
                return view
            }
        }
        #expect(calls == 2)
        #expect(firstModel?.close() == false)
    }

    @Test @MainActor func postWindowLoadFailureRestoresCommittedWindowBaseline() throws {
        let ghostty = TerminalControllerTestHarness.sharedApp
        _ = try #require(ghostty.app)
        guard let probe = try coldSurface(ghostty) else { return }
        probe.surfaceModel?.close()
        let baseline = Set(
            TerminalController.all.map(ObjectIdentifier.init))
        let transaction = try TerminalRestoreMaterializer.materialize(
            try state(from: wire()).restorePlan(),
            ghostty: ghostty)

        #expect(throws: InjectedFailure.factory) {
            try transaction.commit {
                throw InjectedFailure.factory
            }
        }
        #expect(
            Set(TerminalController.all.map(ObjectIdentifier.init)) ==
                baseline)
        #expect(transaction.rollback())
    }

    @Test @MainActor func projectionOmitsWholeMixedTabAndKeepsSafeSelection() throws {
        let ghostty = TerminalControllerTestHarness.sharedApp
        let app = try #require(ghostty.app)
        guard let mixedSafe = try coldSurface(ghostty),
              let retainedSafe = try coldSurface(ghostty) else { return }
        let unsafe: Ghostty.SurfaceView = {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "printf unsafe"
            return Ghostty.SurfaceView(app, baseConfig: config)
        }()
        let mixedID = UUID()
        let retainedID = UUID()
        let mixedTree = SplitTree<Ghostty.SurfaceView>(
            root: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(view: mixedSafe),
                right: .leaf(view: unsafe))),
            zoomed: nil)
        let mixed = TerminalSessionState(id: mixedID, surfaceTree: mixedTree)
        let retained = TerminalSessionState(
            id: retainedID,
            surfaceTree: .init(view: retainedSafe))
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Mixed",
            tabs: [mixed, retained],
            selectedTabID: mixedID)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: .init(
                workspaceID: workspace.id,
                tabID: mixedID)))
        defer {
            controller.close()
            mixedSafe.surfaceModel?.close()
            unsafe.surfaceModel?.close()
            retainedSafe.surfaceModel?.close()
        }

        let projection = try TerminalRestoreProjection.makeWire(
            from: controller)
        #expect(projection.workspaces?.count == 1)
        #expect(projection.workspaces?[0].tabs?.map { $0.id } == [
            retainedID.uuidString,
        ])
        #expect(projection.selectedTabID == retainedID.uuidString)

        let registry = OrdinaryWindowSaveRegistry()
        try registry.register(controller)
        let marker = registry.captureSaveOpportunity()
        #expect(marker.marker.status == .eligibleOrdinaryArchivesPresent)
        guard case let .archive(archive) = registry.claimArchive(
            for: controller)
        else {
            Issue.record("eligible controller did not receive an archive")
            return
        }
        #expect(
            archive.wire.workspaces?[0].tabs?.map { $0.id } ==
                [retainedID.uuidString])
        #expect(registry.seal(archive.token, result: .success(())))
        // AppKit can encode the same window twice in one save cycle; the
        // repeat claim replays the frozen archive instead of diverging.
        guard case let .archive(repeated) = registry.claimArchive(
            for: controller)
        else {
            Issue.record("repeat encode within one cycle was rejected")
            return
        }
        #expect(repeated.wire == archive.wire)
        #expect(registry.seal(repeated.token, result: .success(())))
        #expect(registry.sealMarker(marker.token, result: .success(())))
        registry.finalizeOutstandingSaveResults()
        #expect(registry.drainSaveReportCodes().isEmpty)

        let missing = registry.captureSaveOpportunity()
        #expect(registry.sealMarker(missing.token, result: .success(())))
        registry.finalizeOutstandingSaveResults()
        #expect(
            registry.drainSaveReportCodes().contains(
                .saveCallbackMissing))
        guard case .stale = registry.claimArchive(for: controller) else {
            Issue.record("late archive callback was not rejected as stale")
            return
        }
        #expect(
            registry.drainSaveReportCodes().contains(
                .saveCallbackDivergence))

        let failedRegistry = OrdinaryWindowSaveRegistry()
        try failedRegistry.register(controller)
        let failed = failedRegistry.captureSaveOpportunity { _ in
            throw RestoreEncodingFailure.projection
        }
        #expect(failed.marker.status == .eligibleOrdinaryArchivesPresent)
        #expect(failedRegistry.sealMarker(
            failed.token,
            result: .success(())))
        failedRegistry.finalizeOutstandingSaveResults()
        #expect(
            failedRegistry.drainSaveReportCodes().contains(
                .saveEncodingFailed))
    }

    @Test @MainActor func zeroEligibleWindowIsMarkerOnly() throws {
        let ghostty = TerminalControllerTestHarness.sharedApp
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "printf unsafe"
        let unsafe = Ghostty.SurfaceView(app, baseConfig: config)
        let tab = TerminalSessionState(
            id: UUID(),
            surfaceTree: .init(view: unsafe))
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Unsafe",
            tabs: [tab],
            selectedTabID: tab.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: .init(
                workspaceID: workspace.id,
                tabID: tab.id)))
        defer {
            controller.close()
            unsafe.surfaceModel?.close()
        }
        let registry = OrdinaryWindowSaveRegistry()
        try registry.register(controller)

        let marker = registry.captureSaveOpportunity()
        #expect(marker.marker.status == .allOrdinaryWindowsIneligible)
        #expect(controller.window?.isRestorable == false)
        #expect(registry.sealMarker(marker.token, result: .success(())))
    }

    @Test @MainActor func windowFirstEncoderSharesOneSaveOpportunity() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        #expect(delegate.ghostty.config.windowSaveState != "never")
        let ghostty = TerminalControllerTestHarness.sharedApp
        _ = try #require(ghostty.app)
        guard let surface = try coldSurface(ghostty) else { return }
        let tab = TerminalSessionState(
            id: UUID(),
            surfaceTree: .init(view: surface))
        let workspace = WorkspaceSession(
            id: UUID(),
            name: "Window First",
            tabs: [tab],
            selectedTabID: tab.id)
        let controller = try #require(TerminalControllerTestHarness.make(
            workspaces: [workspace],
            selection: .init(
                workspaceID: workspace.id,
                tabID: tab.id)))
        let window = try #require(controller.window)
        defer {
            controller.close()
            surface.surfaceModel?.close()
        }
        delegate.ordinaryWindowSaveRegistry.finalizeOutstandingSaveResults()
        _ = delegate.ordinaryWindowSaveRegistry.drainSaveReportCodes()

        let windowCoder = NSKeyedArchiver(requiringSecureCoding: true)
        controller.window(
            window,
            willEncodeRestorableState: windowCoder)
        #expect(windowCoder.error == nil)
        windowCoder.finishEncoding()
        let appCoder = NSKeyedArchiver(requiringSecureCoding: true)
        delegate.application(
            NSApp,
            willEncodeRestorableState: appCoder)
        #expect(appCoder.error == nil)
        appCoder.finishEncoding()
        let markerDecoder = try NSKeyedUnarchiver(
            forReadingFrom: appCoder.encodedData)
        defer { markerDecoder.finishDecoding() }
        let rawMarker = markerDecoder.decodeObject(
            of: NSString.self,
            forKey: "chostty.ordinaryWindowRestoreMarker.v9") as String?
        #expect(
            OrdinaryWindowSaveMarker.decode(rawMarker) ==
                .decoded(.init(status:
                    .eligibleOrdinaryArchivesPresent)))
    }

    @Test @MainActor func quickTerminalV1BridgeRoundTripsFocusedPaneKeyAndScreenState() throws {
        let state = DummyQuickTerminalRestorableState(.init(
            focusedSurface: paneID.uuidString,
            surfaceTree: .init(view: MockView(id: paneID)),
            screenStateEntries: [:]
        ))
        let decoded: CodableBridge<DummyQuickTerminalRestorableState> = try unarchive(archive(try CodableBridge(state)))

        #expect(decoded.value.internalState.focusedSurface == paneID.uuidString)
        #expect(decoded.value.internalState.screenStateEntries.isEmpty)
    }

    @Test func corruptAndUnsupportedQuickTerminalArchivesReject() throws {
        for version in [0, 2] {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            archiver.encode(
                version,
                forKey: QuickTerminalRestorableState.versionKey)
            archiver.encode(
                "poison" as NSString,
                forKey: QuickTerminalRestorableState.selfKey)
            let decoder = try NSKeyedUnarchiver(
                forReadingFrom: archiver.encodedData)
            defer { decoder.finishDecoding() }
            #expect(QuickTerminalRestorableState(coder: decoder) == nil)
        }

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(
            QuickTerminalRestorableState.version,
            forKey: QuickTerminalRestorableState.versionKey)
        archiver.encode(
            "poison" as NSString,
            forKey: QuickTerminalRestorableState.selfKey)
        let decoder = try NSKeyedUnarchiver(
            forReadingFrom: archiver.encodedData)
        defer { decoder.finishDecoding() }
        #expect(QuickTerminalRestorableState(coder: decoder) == nil)
    }

    private func state(from wire: TerminalRestoreWireSnapshot) throws -> TerminalRestorableState {
        try JSONDecoder().decode(TerminalRestorableState.self, from: JSONEncoder().encode(wire))
    }

    private func encodeOuter(_ state: TerminalRestorableState) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        try state.encode(with: archiver)
        return archiver.encodedData
    }

    private func decodeOuter(_ data: Data) throws -> TerminalRestorableState {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding() }
        return try #require(TerminalRestorableState(coder: unarchiver))
    }

    private func archive<T: NSObject & NSSecureCoding>(_ object: T) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    private func unarchive<T: NSObject & NSSecureCoding>(_ data: Data, as type: T.Type = T.self) throws -> T {
        let object = try NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data)
        return try #require(object)
    }

    private func wire() -> TerminalRestoreWireSnapshot {
        .init(
            physicalWindowID: physicalID.uuidString,
            workspaces: [.init(
                id: workspaceID.uuidString,
                name: "Workspace",
                tabs: [.init(
                    id: tabID.uuidString,
                    title: "Tab",
                    metadataTitle: nil,
                    titleOverride: nil,
                    color: nil,
                    tree: .init(rootIndex: 0, zoomedPaneID: nil, nodes: [.init(kind: "pane", pane: .init(logicalPaneID: paneID.uuidString, currentWorkingDirectory: "/tmp", rawTitle: "", hasUserTitle: false), direction: nil, ratio: nil, first: nil, second: nil)]),
                    focusedPaneID: paneID.uuidString
                )],
                selectedTabID: tabID.uuidString,
                color: nil,
                isCollapsed: false,
                defaultDirectory: nil
            )],
            selectedWorkspaceID: workspaceID.uuidString,
            selectedTabID: tabID.uuidString,
            titleOverride: nil,
            fullscreenMode: nil,
            filesPanel: nil
        )
    }
}

private struct DummyQuickTerminalRestorableState: TerminalRestorable {
    static var version: Int { QuickTerminalRestorableState.version }

    let internalState: QuickTerminalRestorableState.InternalState<MockView>

    init(_ internalState: QuickTerminalRestorableState.InternalState<MockView>) {
        self.internalState = internalState
    }

    init(copy other: DummyQuickTerminalRestorableState) {
        self = other
    }

    init(from decoder: any Decoder) throws {
        internalState = try .init(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}
