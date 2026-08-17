import Foundation
import Testing
@testable import Ghostty

@Suite
struct TerminalRestorePipelineTests {
    private let physicalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let workspaceID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let tabID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let paneID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!

    @Test func markerDecodeDistinguishesAbsentValidAndInvalid() {
        #expect(OrdinaryWindowSaveMarker.decode(nil) == .absent)
        #expect(OrdinaryWindowSaveMarker.decode("1:allOrdinaryWindowsIneligible") ==
            .decoded(.init(status: .allOrdinaryWindowsIneligible)))
        #expect(OrdinaryWindowSaveMarker.decode("2:allOrdinaryWindowsIneligible") == .invalid)
        #expect(OrdinaryWindowSaveMarker.decode("1:unknown") == .invalid)
    }

    @Test @MainActor func markerTokenSealsExactlyOnce() {
        let registry = OrdinaryWindowSaveRegistry()
        let claim = registry.captureSaveOpportunity()
        #expect(claim.marker.status == .noOrdinaryWindowsAtSave)
        #expect(registry.sealMarker(claim.token, result: .success(())))
        #expect(!registry.sealMarker(claim.token, result: .success(())))
        #expect(registry.drainSaveReportCodes() == [.saveCallbackDivergence])
        registry.finalizeOutstandingSaveResults()
        #expect(registry.drainSaveReportCodes().isEmpty)
    }

    @Test @MainActor func unsealedMarkerIsReportedAtOpportunityClose() {
        let registry = OrdinaryWindowSaveRegistry()
        _ = registry.captureSaveOpportunity()
        registry.finalizeOutstandingSaveResults()
        #expect(registry.drainSaveReportCodes() == [.markerWriteMissing])
    }

    @Test @MainActor func eitherCoderCallbackReusesTheOpenOpportunity() {
        let registry = OrdinaryWindowSaveRegistry()
        let first = registry.ensureSaveOpportunity()
        let second = registry.beginApplicationSaveOpportunity()
        #expect(first.token == second.token)
        #expect(registry.sealMarker(first.token, result: .success(())))
        let third = registry.beginApplicationSaveOpportunity()
        #expect(third.token != first.token)
    }

    @Test @MainActor func restoreAttemptFlushIsExactlyOnceAndFailsClosed() {
        let coordinator = RestoreAttemptCoordinator()
        let pending = coordinator.begin()
        let completed = coordinator.begin()
        #expect(coordinator.complete(completed, outcome: .success([])))
        #expect(!coordinator.complete(completed, outcome: .success([])))

        let report = coordinator.finish(marker: .decoded(.init(status: .eligibleOrdinaryArchivesPresent)))
        #expect(report.items.map(\.code).contains(.completionMissing))
        #expect(!coordinator.complete(pending, outcome: .success([])))
        #expect(coordinator.finish(marker: .absent).items.isEmpty)
    }

    @Test @MainActor func disabledRestorationDiscardsPriorEvidence() {
        let coordinator = RestoreAttemptCoordinator()
        _ = coordinator.begin()
        coordinator.discard()
        #expect(
            coordinator.finish(
                marker: .decoded(.init(
                    status: .eligibleOrdinaryArchivesPresent)))
                .items.isEmpty)
    }

    @Test @MainActor func markerAttemptMatrixAggregatesMixedResults() {
        let coordinator = RestoreAttemptCoordinator()
        let success = coordinator.begin()
        let failure = coordinator.begin()
        #expect(coordinator.complete(
            success,
            outcome: .success([
                .focusAttachmentFailed,
                .currentWorkingDirectoryFallback,
            ])))
        #expect(coordinator.complete(failure, outcome: .failure(.materializationFailed)))
        let report = coordinator.finish(marker: .decoded(.init(status: .eligibleOrdinaryArchivesPresent)))
        #expect(report.items.map(\.code).contains(.focusAttachmentWarning))
        #expect(report.items.map(\.code).contains(.cwdFallback))
        #expect(report.items.map(\.code).contains(.materializationFailed))
    }

    @Test func payloadBoundaryAndBoundaryPlusOne() throws {
        let boundary = Data(repeating: 0, count: TerminalRestoreLimits.payloadBytes)
        let decoded = try TerminalRestoreWireSnapshot.decodePayload(boundary) { _ in wire() }
        #expect(decoded.physicalWindowID != nil)

        let oversized = Data(repeating: 0, count: TerminalRestoreLimits.payloadBytes + 1)
        #expect(throws: RestoreDecodeFailure.payloadOversized) {
            try TerminalRestoreWireSnapshot.decodePayload(oversized) { _ in wire() }
        }
    }

    @Test func stringAndRecordBoundsRejectBeforeSchemaConversion() throws {
        var value = wire()
        value.workspaces![0].name = String(repeating: "a", count: TerminalRestoreLimits.stringBytes)
        try value.validateBounds()
        value.workspaces![0].name!.append("a")
        #expect(throws: RestoreDecodeFailure.budgetExceeded(path: "workspaces[0].name")) { try value.validateBounds() }

        value = wire()
        value.workspaces![0].tabs![0].tree!.nodes = Array(repeating: value.workspaces![0].tabs![0].tree!.nodes![0], count: TerminalRestoreLimits.recordsPerTab + 1)
        #expect(throws: RestoreDecodeFailure.budgetExceeded(path: "workspaces[0].tabs[0].tree.nodes")) { try value.validateBounds() }
    }

    @Test func malformedIdentifierAndUnknownEnumHaveStableContext() throws {
        var value = wire()
        value.workspaces![0].tabs![0].tree!.nodes![0].pane!.logicalPaneID = "not-an-id"
        #expect(throws: RestoreSchemaFailure.identifierMalformed(kind: "logicalPane", path: "workspaces[0].tabs[0].tree.nodes[0].pane.logicalPaneID")) {
            try TerminalRestoreSchemaDecoder.convert(value)
        }

        value = wire()
        value.workspaces![0].tabs![0].tree!.nodes![0] = .init(kind: "split", pane: nil, direction: "diagonal", ratio: 0.5, first: 0, second: 1)
        #expect(throws: RestoreSchemaFailure.enumUnknown(kind: "splitDirection", path: "workspaces[0].tabs[0].tree.nodes[0].direction")) {
            try TerminalRestoreSchemaDecoder.convert(value)
        }

        value = wire()
        value.workspaces![0].tabs![0].tree!.nodes![0].kind = "unknown"
        #expect(throws: RestoreSchemaFailure.enumUnknown(
            kind: "paneNodeKind",
            path: "workspaces[0].tabs[0].tree.nodes[0].kind")) {
            try TerminalRestoreSchemaDecoder.convert(value)
        }
    }

    @Test func graphAdversariesAndRatiosRejectWholeArchive() throws {
        var snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces[0].tabs[0].tree.nodes = [
            .split(direction: .horizontal, ratio: 0.5, first: 1, second: 1),
            .pane(.init(logicalPaneID: paneID, currentWorkingDirectory: nil, rawTitle: "", hasUserTitle: false)),
        ]
        #expect(throws: RestoreValidationFailure.invariant(path: "workspaces[0].tabs[0].tree.nodes[0]")) { try TerminalRestoreValidator.validate(snapshot) }

        snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces[0].tabs[0].tree.nodes = [
            .split(direction: .horizontal, ratio: .nan, first: 1, second: 2),
            .pane(.init(logicalPaneID: paneID, currentWorkingDirectory: nil, rawTitle: "", hasUserTitle: false)),
            .pane(.init(logicalPaneID: UUID(), currentWorkingDirectory: nil, rawTitle: "", hasUserTitle: false)),
        ]
        #expect(throws: RestoreValidationFailure.invalidValue(path: "workspaces[0].tabs[0].tree.nodes[0].ratio")) { try TerminalRestoreValidator.validate(snapshot) }
    }

    @Test func duplicateAndEmptyStructuresReject() throws {
        var snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces.append(snapshot.workspaces[0])
        #expect(throws: RestoreValidationFailure.duplicateIdentifier(path: "workspaces[1].id")) { try TerminalRestoreValidator.validate(snapshot) }

        snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces[0].tabs = []
        #expect(throws: RestoreValidationFailure.invariant(path: "workspaces[0].tabs")) { try TerminalRestoreValidator.validate(snapshot) }
    }

    @Test func staleSelectionsAndFocusNormalizeInArchiveOrder() throws {
        var snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.selectedWorkspaceID = UUID()
        snapshot.selectedTabID = UUID()
        snapshot.workspaces[0].selectedTabID = UUID()
        snapshot.workspaces[0].tabs[0].focusedPaneID = UUID()
        let plan = try TerminalRestoreValidator.validate(snapshot)
        #expect(plan.snapshot.selectedWorkspaceID == workspaceID)
        #expect(plan.snapshot.selectedTabID == tabID)
        #expect(plan.snapshot.workspaces[0].selectedTabID == tabID)
        #expect(plan.snapshot.workspaces[0].tabs[0].focusedPaneID == paneID)
        #expect(plan.warnings.contains(.normalizedWindowSelection))
        #expect(plan.warnings.contains(.normalizedWorkspaceSelection(workspaceIndex: 0)))
        #expect(plan.warnings.contains(.normalizedFocus(workspaceIndex: 0, tabIndex: 0)))
    }

    @Test func invalidFilesPanelStateRejectsInsteadOfClamping() throws {
        var snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.filesPanel = .init(visible: true, width: 219, rootMode: .followPWD, pinnedRoot: nil, showHidden: false)
        #expect(throws: RestoreValidationFailure.invalidValue(path: "filesPanel.width")) { try TerminalRestoreValidator.validate(snapshot) }
    }

    @Test func treeDepth64PassesAnd65Fails() throws {
        var snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces[0].tabs[0].tree = deepTree(depth: 64)
        _ = try TerminalRestoreValidator.validate(snapshot)

        snapshot = try TerminalRestoreSchemaDecoder.convert(wire())
        snapshot.workspaces[0].tabs[0].tree = deepTree(depth: 65)
        #expect(throws: RestoreValidationFailure.budgetExceeded(
            path: "workspaces[0].tabs[0].tree.depth")) {
            try TerminalRestoreValidator.validate(snapshot)
        }
    }

    @Test func persistedProjectionTrackerCoalescesAndRetriesOnce() {
        let initial = wire()
        var changed = initial
        changed.titleOverride = "changed"
        var tracker = TerminalPersistedProjectionTracker()
        tracker.seed(initial)
        let unchangedObserved = tracker.observe(initial)
        let changedObserved = tracker.observe(changed)
        let duplicateObserved = tracker.observe(changed)
        let firstFailure = tracker.failedByCoder()
        let secondFailure = tracker.failedByCoder()
        let retryObserved = tracker.observe(changed, resetRetryBudget: false)
        let changedDuringEncode = tracker.acceptedByCoder(changed)
        let acceptedObserved = tracker.observe(changed)
        #expect(!unchangedObserved)
        #expect(changedObserved)
        #expect(!duplicateObserved)
        #expect(firstFailure)
        #expect(!secondFailure)
        #expect(retryObserved)
        #expect(changedDuringEncode == false)
        #expect(!acceptedObserved)
    }

    @Test func persistedProjectionTrackerDetectsLiveMutationDuringEncode() {
        let initial = wire()
        var encoded = initial
        encoded.titleOverride = "encoded"
        var live = encoded
        live.titleOverride = "later"
        var tracker = TerminalPersistedProjectionTracker()
        tracker.seed(initial)
        let encodedObserved = tracker.observe(encoded)
        let liveObserved = tracker.observe(live)
        let changedDuringEncode = tracker.acceptedByCoder(encoded)
        #expect(encodedObserved)
        #expect(liveObserved == false)
        #expect(changedDuringEncode)
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

    private func deepTree(depth: Int) -> PaneTreeSnapshot {
        var nodes: [PaneTreeSnapshot.Node] = []
        func append(level: Int) -> Int {
            let index = nodes.count
            nodes.append(.pane(.init(
                logicalPaneID: UUID(),
                currentWorkingDirectory: nil,
                rawTitle: "",
                hasUserTitle: false)))
            guard level < depth else { return index }
            let first = append(level: level + 1)
            let second = nodes.count
            nodes.append(.pane(.init(
                logicalPaneID: UUID(),
                currentWorkingDirectory: nil,
                rawTitle: "",
                hasUserTitle: false)))
            nodes[index] = .split(
                direction: .horizontal,
                ratio: 0.5,
                first: first,
                second: second)
            return index
        }
        return .init(
            rootIndex: append(level: 1),
            zoomedPaneID: nil,
            nodes: nodes)
    }
}
