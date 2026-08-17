import AppKit
import Foundation
import GhosttyKit

/// Fixed limits for the ordinary-window v9 archive. These are intentionally not configurable.
enum TerminalRestoreLimits {
    static let payloadBytes = 8 * 1024 * 1024
    static let workspacesPerWindow = 64
    static let tabsPerWindow = 512
    static let panesPerTab = 256
    static let panesPerWindow = 2_048
    static let recordsPerTab = 511
    static let recordsPerWindow = 4_095
    static let treeDepth = 64
    static let stringBytes = 4 * 1024
    static let pathBytes = 16 * 1024
    static let enumBytes = 64
}

enum RestoreDecodeFailure: Error, Equatable, Sendable {
    case payloadMissing
    case payloadOversized
    case payloadMalformed
    case budgetExceeded(path: String)
    case budgetOverflow(path: String)

    var code: String {
        switch self {
        case .payloadMissing: "R_PAYLOAD_MISSING"
        case .payloadOversized: "R_PAYLOAD_OVERSIZED"
        case .payloadMalformed: "R_PAYLOAD_MALFORMED"
        case .budgetExceeded: "R_BUDGET_EXCEEDED"
        case .budgetOverflow: "R_BUDGET_OVERFLOW"
        }
    }
}

enum RestoreSchemaFailure: Error, Equatable, Sendable {
    case fieldMissing(path: String)
    case identifierMalformed(kind: String, path: String)
    case enumUnknown(kind: String, path: String)

    var code: String {
        switch self {
        case .fieldMissing: "R_FIELD_MISSING"
        case .identifierMalformed: "R_ID_MALFORMED"
        case .enumUnknown: "R_ENUM_UNKNOWN"
        }
    }
}

enum RestoreValidationFailure: Error, Equatable, Sendable {
    case invariant(path: String)
    case duplicateIdentifier(path: String)
    case invalidValue(path: String)
    case budgetExceeded(path: String)
    case budgetOverflow(path: String)

    var code: String {
        switch self {
        case .invariant: "R_GRAPH_INVALID"
        case .duplicateIdentifier: "R_ID_DUPLICATE"
        case .invalidValue: "R_VALUE_INVALID"
        case .budgetExceeded: "R_BUDGET_EXCEEDED"
        case .budgetOverflow: "R_BUDGET_OVERFLOW"
        }
    }
}

enum RestoreMaterializationFailure: Error, Equatable, Sendable {
    case coldPolicyMismatch
    case surfaceFactory
    case explicitClose
    case windowLoad
    case publication
}

enum RestoreEncodingFailure: Error, Equatable, Sendable {
    case projection
    case innerPayload
    case payloadSize
    case outerCoder
    case enrollment
}

enum RestoreWarning: Equatable, Sendable {
    case normalizedWindowSelection
    case normalizedWorkspaceSelection(workspaceIndex: Int)
    case normalizedFocus(workspaceIndex: Int, tabIndex: Int)
    case currentWorkingDirectoryFallback
    case focusAttachmentFailed
}

/// Content-free process-level evidence of the last ordinary-window save opportunity.
enum OrdinaryWindowSaveMarkerStatus: String, Codable, Sendable {
    case noOrdinaryWindowsAtSave
    case allOrdinaryWindowsIneligible
    case eligibleOrdinaryArchivesPresent
}

struct OrdinaryWindowSaveMarker: Codable, Equatable, Sendable {
    static let version = 1
    let version: Int
    let status: OrdinaryWindowSaveMarkerStatus

    init(status: OrdinaryWindowSaveMarkerStatus) {
        self.version = Self.version
        self.status = status
    }

    var encoded: String { "\(version):\(status.rawValue)" }

    static func decode(_ value: String?) -> MarkerReadState {
        guard let value else { return .absent }
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let version = Int(parts[0]), version == Self.version,
              let status = OrdinaryWindowSaveMarkerStatus(rawValue: String(parts[1]))
        else { return .invalid }
        return .decoded(.init(status: status))
    }
}

enum MarkerReadState: Equatable, Sendable {
    case unread
    case absent
    case decoded(OrdinaryWindowSaveMarker)
    case invalid
    case consumed
}

@MainActor
final class OrdinaryWindowSaveRegistry {
    typealias Projection = @MainActor (
        TerminalController
    ) throws -> TerminalRestoreWireSnapshot
    private struct Entry {
        weak var controller: TerminalController?
        weak var window: NSWindow?
    }
    struct Token: Equatable, Sendable { fileprivate let opportunity: UInt64; fileprivate let participant: ObjectIdentifier }
    struct MarkerToken: Equatable, Sendable { fileprivate let opportunity: UInt64 }
    struct MarkerClaim {
        let token: MarkerToken
        let marker: OrdinaryWindowSaveMarker
    }
    enum ArchiveClaim {
        case archive(ClaimedArchive)
        case stale
    }
    struct ClaimedArchive { let token: Token; let wire: TerminalRestoreWireSnapshot }
    enum CallbackState {
        case unclaimed
        case claimed(Token)
        case result(Result<Void, RestoreEncodingFailure>)
        case missing
        case reported
    }
    private struct SaveOpportunity {
        let id: UInt64
        let marker: OrdinaryWindowSaveMarker
        let archives: [ObjectIdentifier: TerminalRestoreWireSnapshot]
        let preflightFailures: [ObjectIdentifier: RestoreEncodingFailure]
        var callbacks: [ObjectIdentifier: CallbackState]
        var markerResult: Result<Void, RestoreEncodingFailure>?
        var preflightReported: Bool
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextOpportunity: UInt64 = 0
    private var opportunities: [SaveOpportunity] = []
    private var saveReportCodes: [TerminalRestoreReportCode] = []

    func register(_ controller: TerminalController) throws {
        guard let window = controller.window, window.windowController === controller else {
            throw RestoreMaterializationFailure.publication
        }
        entries[ObjectIdentifier(controller)] = .init(controller: controller, window: window)
        guard contains(controller) else {
            entries.removeValue(forKey: ObjectIdentifier(controller))
            throw RestoreMaterializationFailure.publication
        }
    }
    func remove(_ controller: TerminalController) {
        let participant = ObjectIdentifier(controller)
        entries.removeValue(forKey: participant)
    }

    func contains(_ controller: TerminalController) -> Bool {
        let key = ObjectIdentifier(controller)
        guard let entry = entries[key],
              entry.controller === controller,
              let window = entry.window else { return false }
        return controller.window === window && window.windowController === controller
    }

    /// Captures marker participants and archive participants from one immutable instant.
    func captureSaveOpportunity(
        projection: Projection = TerminalRestoreProjection.makeWire
    ) -> MarkerClaim {
        sealOutstanding()
        entries = entries.filter { $0.value.controller != nil && $0.value.window != nil }
        let participants = entries.compactMap { key, entry -> TerminalController? in
            guard let controller = entry.controller, let window = entry.window,
                  window.windowController === controller else { return nil }
            return controller
        }
        var archives: [ObjectIdentifier: TerminalRestoreWireSnapshot] = [:]
        var eligibleParticipants = Set<ObjectIdentifier>()
        var preflightFailures: [ObjectIdentifier: RestoreEncodingFailure] = [:]
        for controller in participants {
            controller.schedulePersistedProjectionComparison(resetRetryBudget: true)
            let participant = ObjectIdentifier(controller)
            let eligible = controller.workspaceStore.snapshot.workspaces.contains {
                $0.tabs.contains(where: \.isRestorationEligible)
            }
            guard eligible else {
                controller.disableRestorationEnrollment()
                continue
            }
            eligibleParticipants.insert(participant)
            do {
                let wire = try projection(controller)
                guard wire.workspaces?.isEmpty == false else {
                    preflightFailures[participant] = .projection
                    controller.disableRestorationEnrollment()
                    continue
                }
                archives[participant] = wire
                controller.refreshRestorationEnrollment()
                guard controller.window?.isRestorable == true,
                      controller.window?.restorationClass === TerminalWindowRestoration.self,
                      controller.window?.identifier == .init(String(describing: TerminalWindowRestoration.self))
                else {
                    archives.removeValue(forKey: participant)
                    preflightFailures[participant] = .enrollment
                    controller.disableRestorationEnrollment()
                    continue
                }
            } catch {
                preflightFailures[participant] = .projection
                controller.coderFailedPersistedProjection()
                controller.window?.isRestorable = false
                controller.window?.restorationClass = nil
                controller.window?.identifier = nil
            }
        }
        let status: OrdinaryWindowSaveMarkerStatus = participants.isEmpty
            ? .noOrdinaryWindowsAtSave
            : eligibleParticipants.isEmpty
                ? .allOrdinaryWindowsIneligible
                : .eligibleOrdinaryArchivesPresent
        nextOpportunity += 1
        let marker = OrdinaryWindowSaveMarker(status: status)
        let callbacks = Dictionary(uniqueKeysWithValues: archives.keys.map { ($0, CallbackState.unclaimed) })
        opportunities.append(.init(
            id: nextOpportunity,
            marker: marker,
            archives: archives,
            preflightFailures: preflightFailures,
            callbacks: callbacks,
            markerResult: nil,
            preflightReported: false))
        if opportunities.count > 4 { opportunities.removeFirst(opportunities.count - 4) }
        return .init(token: .init(opportunity: nextOpportunity), marker: marker)
    }

    /// Returns the one open opportunity regardless of whether the app- or
    /// window-level NSCoder callback arrived first.
    func ensureSaveOpportunity() -> MarkerClaim {
        if let opportunity = opportunities.last {
            let callbacksOpen = opportunity.callbacks.values.contains {
                switch $0 {
                case .unclaimed, .claimed: true
                default: false
                }
            }
            if opportunity.markerResult == nil || callbacksOpen {
                return .init(
                    token: .init(opportunity: opportunity.id),
                    marker: opportunity.marker)
            }
        }
        return captureSaveOpportunity()
    }

    /// The application callback starts a new save cycle unless a window
    /// callback already opened the current cycle and its marker is unsealed.
    func beginApplicationSaveOpportunity() -> MarkerClaim {
        if let opportunity = opportunities.last,
           opportunity.markerResult == nil {
            return .init(
                token: .init(opportunity: opportunity.id),
                marker: opportunity.marker)
        }
        return captureSaveOpportunity()
    }

    /// AppKit may encode the same window more than once inside one save
    /// cycle. A repeat claim therefore hands back the same frozen archive
    /// under the same token instead of reporting divergence; only a claim
    /// that no longer belongs to the current opportunity is stale.
    func claimArchive(for controller: TerminalController) -> ArchiveClaim? {
        let participant = ObjectIdentifier(controller)
        guard let index = opportunities.indices.last,
              let wire = opportunities[index].archives[participant]
        else {
            guard opportunities.contains(where: {
                $0.archives[participant] != nil
            }) else { return nil }
            saveReportCodes.append(.saveCallbackDivergence)
            return .stale
        }
        let token = Token(opportunity: opportunities[index].id, participant: participant)
        switch opportunities[index].callbacks[participant] {
        case .unclaimed, .claimed, .result:
            opportunities[index].callbacks[participant] = .claimed(token)
            return .archive(.init(token: token, wire: wire))
        default:
            saveReportCodes.append(.saveCallbackDivergence)
            return .stale
        }
    }

    func seal(_ token: Token, result: Result<Void, RestoreEncodingFailure>) -> Bool {
        guard let index = opportunities.firstIndex(where: { $0.id == token.opportunity }),
              case .claimed(token) = opportunities[index].callbacks[token.participant]
        else {
            saveReportCodes.append(.saveCallbackDivergence)
            return false
        }
        opportunities[index].callbacks[token.participant] = .result(result)
        return true
    }

    func sealMarker(
        _ token: MarkerToken,
        result: Result<Void, RestoreEncodingFailure>
    ) -> Bool {
        guard let index = opportunities.firstIndex(where: {
            $0.id == token.opportunity
        }), opportunities[index].markerResult == nil else {
            saveReportCodes.append(.saveCallbackDivergence)
            return false
        }
        opportunities[index].markerResult = result
        if case .failure = result {
            saveReportCodes.append(.saveEncodingFailed)
        }
        return true
    }

    private func sealOutstanding() {
        for index in opportunities.indices {
            if !opportunities[index].preflightReported {
                for _ in opportunities[index].preflightFailures {
                    saveReportCodes.append(.saveEncodingFailed)
                }
                opportunities[index].preflightReported = true
            }
            if opportunities[index].markerResult == nil {
                opportunities[index].markerResult = .failure(.outerCoder)
                saveReportCodes.append(.markerWriteMissing)
            }
            for participant in opportunities[index].callbacks.keys {
                switch opportunities[index].callbacks[participant] {
                case .unclaimed, .claimed:
                    opportunities[index].callbacks[participant] = .missing
                    saveReportCodes.append(.saveCallbackMissing)
                case .result(.failure):
                    opportunities[index].callbacks[participant] = .reported
                    saveReportCodes.append(.saveEncodingFailed)
                default:
                    break
                }
            }
        }
    }

    func finalizeOutstandingSaveResults() {
        sealOutstanding()
    }

    func drainSaveReportCodes() -> [TerminalRestoreReportCode] {
        defer { saveReportCodes.removeAll(keepingCapacity: true) }
        return saveReportCodes
    }

    var hasCommittedController: Bool {
        entries.values.contains { $0.controller != nil }
    }
}

enum TerminalRestoreReportCode: String, Sendable {
    case restoreAttemptMissing = "R_RESTORE_ATTEMPT_MISSING"
    case completionMissing = "R_RESTORE_COMPLETION_MISSING"
    case archiveRejected = "R_ARCHIVE_REJECTED"
    case decodeRejected = "R_DECODE_REJECTED"
    case schemaRejected = "R_SCHEMA_REJECTED"
    case validationRejected = "R_VALIDATION_REJECTED"
    case materializationFailed = "R_MATERIALIZATION_FAILED"
    case publicationFailed = "R_PUBLICATION_FAILED"
    case cleanupFailed = "R_CLEANUP_FAILED"
    case allIneligible = "R_ALL_INELIGIBLE"
    case v8Discarded = "R_V8_DISCARDED"
    case focusAttachmentWarning = "R_FOCUS_ATTACHMENT_WARNING"
    case cwdFallback = "R_CWD_FALLBACK"
    case saveCallbackMissing = "R_SAVE_CALLBACK_MISSING"
    case saveCallbackDivergence = "R_SAVE_CALLBACK_DIVERGENCE"
    case saveEncodingFailed = "R_SAVE_ENCODING_FAILED"
    case markerDivergence = "R_MARKER_DIVERGENCE"
    case markerWriteMissing = "R_MARKER_WRITE_MISSING"
    case additionalFailuresOmitted = "R_ADDITIONAL_FAILURES_OMITTED"
}

struct TerminalRestoreReport: Sendable {
    struct Item: Sendable { let code: TerminalRestoreReportCode }
    var items: [Item] = []
    mutating func append(_ code: TerminalRestoreReportCode) {
        guard items.count < 32 else {
            if !items.contains(where: { $0.code == .additionalFailuresOmitted }) {
                items.append(.init(code: .additionalFailuresOmitted))
            }
            return
        }
        items.append(.init(code: code))
    }
}

@MainActor
final class RestoreAttemptCoordinator {
    struct Token: Hashable, Sendable { fileprivate let id: UInt64 }
    enum Outcome: Sendable {
        case success([RestoreWarning])
        case failure(TerminalRestoreReportCode)
    }

    private var nextID: UInt64 = 0
    private var pending: Set<Token> = []
    private var outcomes: [Outcome] = []
    private(set) var finished = false

    func begin() -> Token {
        nextID += 1
        let token = Token(id: nextID)
        pending.insert(token)
        return token
    }

    /// Returns false for a duplicate/stale completion; callers must not invoke AppKit twice.
    func complete(_ token: Token, outcome: Outcome) -> Bool {
        guard pending.remove(token) != nil, !finished else { return false }
        outcomes.append(outcome)
        return true
    }

    func finish(marker: MarkerReadState) -> TerminalRestoreReport {
        guard !finished else { return .init() }
        finished = true
        var report = TerminalRestoreReport()
        for _ in pending { report.append(.completionMissing) }
        pending.removeAll()
        for outcome in outcomes {
            switch outcome {
            case let .success(warnings):
                if warnings.contains(.focusAttachmentFailed) { report.append(.focusAttachmentWarning) }
                if warnings.contains(.currentWorkingDirectoryFallback) { report.append(.cwdFallback) }
            case let .failure(code): report.append(code)
            }
        }
        switch marker {
        case .decoded(let marker):
            switch marker.status {
            case .eligibleOrdinaryArchivesPresent where attemptCount == 0:
                report.append(.restoreAttemptMissing)
            case .allOrdinaryWindowsIneligible:
                report.append(.allIneligible)
                if attemptCount != 0 {
                    report.append(.markerDivergence)
                }
            case .noOrdinaryWindowsAtSave where attemptCount != 0:
                report.append(.markerDivergence)
            default: break
            }
        case .invalid: report.append(.archiveRejected)
        default: break
        }
        return report
    }

    func discard() {
        pending.removeAll()
        outcomes.removeAll()
        finished = true
    }

    var attemptCount: Int { Int(nextID) }
}

/// Exactly the ordinary-window values that are eligible for persistence.
/// This is intentionally the wire projection: it excludes runtime state by shape.
typealias TerminalPersistedProjection = TerminalRestoreWireSnapshot

private struct TerminalRestoreDecodeBudget {
    var tabs = 0
    var panes = 0
    var nodes = 0
}

/// Pure state machine behind the controller-owned coalescing scheduler.
struct TerminalPersistedProjectionTracker {
    private(set) var observed: TerminalPersistedProjection?
    private(set) var accepted: TerminalPersistedProjection?
    private(set) var invalidationOutstanding = false
    private(set) var automaticRetryUsed = false

    mutating func seed(_ projection: TerminalPersistedProjection) {
        observed = projection; accepted = projection; invalidationOutstanding = false; automaticRetryUsed = false
    }
    mutating func observe(_ projection: TerminalPersistedProjection, resetRetryBudget: Bool = true) -> Bool {
        observed = projection
        if resetRetryBudget { automaticRetryUsed = false }
        guard projection != accepted, !invalidationOutstanding else { return false }
        invalidationOutstanding = true
        return true
    }
    mutating func acceptedByCoder(_ projection: TerminalPersistedProjection) -> Bool {
        accepted = projection; invalidationOutstanding = false; automaticRetryUsed = false
        return observed != projection
    }
    mutating func failedByCoder() -> Bool {
        invalidationOutstanding = false
        guard !automaticRetryUsed else { return false }
        automaticRetryUsed = true
        return true
    }
}

/// Raw v9 values. Strings remain unparsed here so the schema boundary can report stable errors.
struct TerminalRestoreWireSnapshot: Codable, Sendable, Equatable {
    var physicalWindowID: String?
    var workspaces: [Workspace]?
    var selectedWorkspaceID: String?
    var selectedTabID: String?
    var titleOverride: String?
    var fullscreenMode: String?
    var filesPanel: FilesPanel?

    private enum CodingKeys: String, CodingKey {
        case physicalWindowID, workspaces, selectedWorkspaceID, selectedTabID, titleOverride, fullscreenMode, filesPanel
    }
    init(physicalWindowID: String?, workspaces: [Workspace]?, selectedWorkspaceID: String?, selectedTabID: String?, titleOverride: String?, fullscreenMode: String?, filesPanel: FilesPanel?) {
        self.physicalWindowID = physicalWindowID; self.workspaces = workspaces; self.selectedWorkspaceID = selectedWorkspaceID; self.selectedTabID = selectedTabID; self.titleOverride = titleOverride; self.fullscreenMode = fullscreenMode; self.filesPanel = filesPanel
    }
    init(from decoder: Decoder) throws {
        var budget = TerminalRestoreDecodeBudget()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        physicalWindowID = try c.decodeIfPresent(String.self, forKey: .physicalWindowID)
        if c.contains(.workspaces), !(try c.decodeNil(forKey: .workspaces)) {
            var values = try c.nestedUnkeyedContainer(forKey: .workspaces)
            var decoded: [Workspace] = []
            while !values.isAtEnd {
                try count(
                    decoded.count + 1,
                    maximum: TerminalRestoreLimits.workspacesPerWindow,
                    path: "workspaces")
                decoded.append(try Workspace.decode(
                    from: values.superDecoder(),
                    budget: &budget))
            }
            workspaces = decoded
        } else {
            workspaces = nil
        }
        selectedWorkspaceID = try c.decodeIfPresent(String.self, forKey: .selectedWorkspaceID)
        selectedTabID = try c.decodeIfPresent(String.self, forKey: .selectedTabID)
        titleOverride = try c.decodeIfPresent(String.self, forKey: .titleOverride)
        fullscreenMode = try c.decodeIfPresent(String.self, forKey: .fullscreenMode)
        filesPanel = try c.decodeIfPresent(FilesPanel.self, forKey: .filesPanel)
    }

    struct Workspace: Codable, Sendable, Equatable {
        var id: String?
        var name: String?
        var tabs: [Tab]?
        var selectedTabID: String?
        var color: String?
        var isCollapsed: Bool?
        var defaultDirectory: String?
        init(id: String?, name: String?, tabs: [Tab]?, selectedTabID: String?, color: String?, isCollapsed: Bool?, defaultDirectory: String?) {
            self.id = id; self.name = name; self.tabs = tabs; self.selectedTabID = selectedTabID; self.color = color; self.isCollapsed = isCollapsed; self.defaultDirectory = defaultDirectory
        }
        private enum CodingKeys: String, CodingKey { case id, name, tabs, selectedTabID, color, isCollapsed, defaultDirectory }
        init(from decoder: Decoder) throws {
            var budget = TerminalRestoreDecodeBudget()
            self = try Self.decode(from: decoder, budget: &budget)
        }
        fileprivate static func decode(
            from decoder: Decoder,
            budget: inout TerminalRestoreDecodeBudget
        ) throws -> Self {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var tabs: [Tab]?
            if c.contains(.tabs), !(try c.decodeNil(forKey: .tabs)) {
                var values = try c.nestedUnkeyedContainer(forKey: .tabs)
                var decoded: [Tab] = []
                while !values.isAtEnd {
                    try add(
                        1,
                        to: &budget.tabs,
                        maximum: TerminalRestoreLimits.tabsPerWindow,
                        path: "tabs")
                    decoded.append(try Tab.decode(
                        from: values.superDecoder(),
                        budget: &budget))
                }
                tabs = decoded
            }
            return .init(
                id: try c.decodeIfPresent(String.self, forKey: .id),
                name: try c.decodeIfPresent(String.self, forKey: .name),
                tabs: tabs,
                selectedTabID: try c.decodeIfPresent(String.self, forKey: .selectedTabID),
                color: try c.decodeIfPresent(String.self, forKey: .color),
                isCollapsed: try c.decodeIfPresent(Bool.self, forKey: .isCollapsed),
                defaultDirectory: try c.decodeIfPresent(String.self, forKey: .defaultDirectory))
        }
    }

    struct Tab: Codable, Sendable, Equatable {
        var id: String?
        var title: String?
        var metadataTitle: String?
        var titleOverride: String?
        var color: String?
        var tree: PaneTree?
        var focusedPaneID: String?
        init(id: String?, title: String?, metadataTitle: String?, titleOverride: String?, color: String?, tree: PaneTree?, focusedPaneID: String?) {
            self.id = id; self.title = title; self.metadataTitle = metadataTitle; self.titleOverride = titleOverride; self.color = color; self.tree = tree; self.focusedPaneID = focusedPaneID
        }
        private enum CodingKeys: String, CodingKey { case id, title, metadataTitle, titleOverride, color, tree, focusedPaneID }
        init(from decoder: Decoder) throws {
            var budget = TerminalRestoreDecodeBudget()
            self = try Self.decode(from: decoder, budget: &budget)
        }
        fileprivate static func decode(
            from decoder: Decoder,
            budget: inout TerminalRestoreDecodeBudget
        ) throws -> Self {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tree: PaneTree?
            if c.contains(.tree), !(try c.decodeNil(forKey: .tree)) {
                tree = try PaneTree.decode(
                    from: c.superDecoder(forKey: .tree),
                    budget: &budget)
            } else {
                tree = nil
            }
            return .init(
                id: try c.decodeIfPresent(String.self, forKey: .id),
                title: try c.decodeIfPresent(String.self, forKey: .title),
                metadataTitle: try c.decodeIfPresent(String.self, forKey: .metadataTitle),
                titleOverride: try c.decodeIfPresent(String.self, forKey: .titleOverride),
                color: try c.decodeIfPresent(String.self, forKey: .color),
                tree: tree,
                focusedPaneID: try c.decodeIfPresent(String.self, forKey: .focusedPaneID))
        }
    }

    struct Pane: Codable, Sendable, Equatable {
        var logicalPaneID: String?
        var currentWorkingDirectory: String?
        var rawTitle: String?
        var hasUserTitle: Bool?
    }

    struct PaneTree: Codable, Sendable, Equatable {
        var rootIndex: Int?
        var zoomedPaneID: String?
        var nodes: [Node]?
        init(rootIndex: Int?, zoomedPaneID: String?, nodes: [Node]?) {
            self.rootIndex = rootIndex; self.zoomedPaneID = zoomedPaneID; self.nodes = nodes
        }
        private enum CodingKeys: String, CodingKey { case rootIndex, zoomedPaneID, nodes }
        init(from decoder: Decoder) throws {
            var budget = TerminalRestoreDecodeBudget()
            self = try Self.decode(from: decoder, budget: &budget)
        }
        fileprivate static func decode(
            from decoder: Decoder,
            budget: inout TerminalRestoreDecodeBudget
        ) throws -> Self {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var nodes: [Node]?
            if c.contains(.nodes), !(try c.decodeNil(forKey: .nodes)) {
                var values = try c.nestedUnkeyedContainer(forKey: .nodes)
                var decoded: [Node] = []
                var panes = 0
                while !values.isAtEnd {
                    try count(
                        decoded.count + 1,
                        maximum: TerminalRestoreLimits.recordsPerTab,
                        path: "nodes")
                    try add(
                        1,
                        to: &budget.nodes,
                        maximum: TerminalRestoreLimits.recordsPerWindow,
                        path: "nodes")
                    let node = try values.decode(Node.self)
                    if node.pane != nil {
                        try count(
                            panes + 1,
                            maximum: TerminalRestoreLimits.panesPerTab,
                            path: "panes")
                        panes += 1
                        try add(
                            1,
                            to: &budget.panes,
                            maximum: TerminalRestoreLimits.panesPerWindow,
                            path: "panes")
                    }
                    decoded.append(node)
                }
                nodes = decoded
            }
            return .init(
                rootIndex: try c.decodeIfPresent(Int.self, forKey: .rootIndex),
                zoomedPaneID: try c.decodeIfPresent(String.self, forKey: .zoomedPaneID),
                nodes: nodes)
        }
    }

    struct Node: Codable, Sendable, Equatable {
        var kind: String?
        var pane: Pane?
        var direction: String?
        var ratio: Double?
        var first: Int?
        var second: Int?
    }

    struct FilesPanel: Codable, Sendable, Equatable {
        var visible: Bool?
        var width: Double?
        var rootMode: String?
        var pinnedRoot: String?
        var showHidden: Bool?
    }

    /// The payload hook checks the byte contract before the caller creates an inner decoder.
    static func decodePayload(
        _ payload: Data?,
        decode: (Data) throws -> TerminalRestoreWireSnapshot
    ) throws -> TerminalRestoreWireSnapshot {
        guard let payload else { throw RestoreDecodeFailure.payloadMissing }
        guard payload.count <= TerminalRestoreLimits.payloadBytes else {
            throw RestoreDecodeFailure.payloadOversized
        }
        do {
            let value = try decode(payload)
            try value.validateBounds()
            return value
        } catch let error as RestoreDecodeFailure {
            throw error
        } catch {
            throw RestoreDecodeFailure.payloadMalformed
        }
    }

    func validateBounds() throws {
        try boundedUUID(physicalWindowID, path: "physicalWindowID")
        try boundedUUID(selectedWorkspaceID, path: "selectedWorkspaceID")
        try boundedUUID(selectedTabID, path: "selectedTabID")
        try boundedString(titleOverride, limit: TerminalRestoreLimits.stringBytes, path: "titleOverride")
        try boundedEnum(fullscreenMode, path: "fullscreenMode")
        guard let workspaces else { return }
        try count(workspaces.count, maximum: TerminalRestoreLimits.workspacesPerWindow, path: "workspaces")
        var totalTabs = 0
        var totalPanes = 0
        var totalNodes = 0
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let prefix = "workspaces[\(workspaceIndex)]"
            try boundedUUID(workspace.id, path: "\(prefix).id")
            try boundedString(workspace.name, limit: TerminalRestoreLimits.stringBytes, path: "\(prefix).name")
            try boundedString(workspace.defaultDirectory, limit: TerminalRestoreLimits.pathBytes, path: "\(prefix).defaultDirectory")
            try boundedEnum(workspace.color, path: "\(prefix).color")
            try boundedUUID(workspace.selectedTabID, path: "\(prefix).selectedTabID")
            guard let tabs = workspace.tabs else { continue }
            try add(tabs.count, to: &totalTabs, maximum: TerminalRestoreLimits.tabsPerWindow, path: "tabs")
            for (tabIndex, tab) in tabs.enumerated() {
                let tabPath = "\(prefix).tabs[\(tabIndex)]"
                try boundedUUID(tab.id, path: "\(tabPath).id")
                try boundedString(tab.title, limit: TerminalRestoreLimits.stringBytes, path: "\(tabPath).title")
                try boundedString(tab.metadataTitle, limit: TerminalRestoreLimits.stringBytes, path: "\(tabPath).metadataTitle")
                try boundedString(tab.titleOverride, limit: TerminalRestoreLimits.stringBytes, path: "\(tabPath).titleOverride")
                try boundedEnum(tab.color, path: "\(tabPath).color")
                try boundedUUID(tab.focusedPaneID, path: "\(tabPath).focusedPaneID")
                guard let tree = tab.tree else { continue }
                try boundedUUID(tree.zoomedPaneID, path: "\(tabPath).tree.zoomedPaneID")
                guard let nodes = tree.nodes else { continue }
                try count(nodes.count, maximum: TerminalRestoreLimits.recordsPerTab, path: "\(tabPath).tree.nodes")
                try add(nodes.count, to: &totalNodes, maximum: TerminalRestoreLimits.recordsPerWindow, path: "nodes")
                var tabPanes = 0
                for (nodeIndex, node) in nodes.enumerated() {
                    let nodePath = "\(tabPath).tree.nodes[\(nodeIndex)]"
                    try boundedEnum(node.kind, path: "\(nodePath).kind")
                    try boundedEnum(node.direction, path: "\(nodePath).direction")
                    if let pane = node.pane {
                        try add(1, to: &tabPanes, maximum: TerminalRestoreLimits.panesPerTab, path: "\(tabPath).panes")
                        try add(1, to: &totalPanes, maximum: TerminalRestoreLimits.panesPerWindow, path: "panes")
                        try boundedUUID(pane.logicalPaneID, path: "\(nodePath).pane.logicalPaneID")
                        try boundedString(pane.currentWorkingDirectory, limit: TerminalRestoreLimits.pathBytes, path: "\(nodePath).pane.currentWorkingDirectory")
                        try boundedString(pane.rawTitle, limit: TerminalRestoreLimits.stringBytes, path: "\(nodePath).pane.rawTitle")
                    }
                }
            }
        }
        if let filesPanel {
            try boundedEnum(filesPanel.rootMode, path: "filesPanel.rootMode")
            try boundedString(filesPanel.pinnedRoot, limit: TerminalRestoreLimits.pathBytes, path: "filesPanel.pinnedRoot")
        }
    }
}

struct TerminalRestoreSnapshot: Sendable, Equatable {
    var physicalWindowID: UUID
    var workspaces: [WorkspaceSnapshot]
    var selectedWorkspaceID: UUID?
    var selectedTabID: UUID?
    var titleOverride: String?
    var fullscreenMode: RestoreFullscreenMode?
    var filesPanel: RestoreFilesPanelSnapshot?
}

struct WorkspaceSnapshot: Sendable, Equatable {
    var id: UUID
    var name: String
    var tabs: [TabSnapshot]
    var selectedTabID: UUID?
    var color: RestoreColor?
    var isCollapsed: Bool
    var defaultDirectory: String?
}

struct TabSnapshot: Sendable, Equatable {
    var id: UUID
    var title: String
    var metadataTitle: String?
    var titleOverride: String?
    var color: RestoreColor?
    var tree: PaneTreeSnapshot
    var focusedPaneID: UUID?
}

struct PaneSnapshot: Sendable, Equatable {
    var logicalPaneID: UUID
    var currentWorkingDirectory: String?
    var rawTitle: String
    var hasUserTitle: Bool
}

struct PaneTreeSnapshot: Sendable, Equatable {
    var rootIndex: Int
    var zoomedPaneID: UUID?
    var nodes: [Node]

    enum Node: Sendable, Equatable {
        case pane(PaneSnapshot)
        case split(direction: RestoreSplitDirection, ratio: Double, first: Int, second: Int)
    }
}

enum RestoreSplitDirection: String, Sendable, Equatable { case horizontal, vertical }
enum RestoreFilesPanelRootMode: String, Sendable, Equatable { case followPWD, pinned }
enum RestoreFullscreenMode: String, Sendable, Equatable {
    case native
    case nonNative
    case nonNativeVisibleMenu
    case nonNativePaddedNotch
}
enum RestoreColor: String, Sendable, Equatable, CaseIterable {
    case none, blue, purple, pink, red, orange, yellow, green, teal, graphite
}

struct RestoreFilesPanelSnapshot: Sendable, Equatable {
    var visible: Bool
    var width: Double
    var rootMode: RestoreFilesPanelRootMode
    var pinnedRoot: String?
    var showHidden: Bool
}

enum TerminalRestoreSchemaDecoder {
    static func convert(_ wire: TerminalRestoreWireSnapshot) throws -> TerminalRestoreSnapshot {
        let physicalWindowID = try identifier(wire.physicalWindowID, kind: "physicalWindow", path: "physicalWindowID")
        guard let wireWorkspaces = wire.workspaces else { throw RestoreSchemaFailure.fieldMissing(path: "workspaces") }
        let workspaces = try wireWorkspaces.enumerated().map { index, workspace in
            try convert(workspace, path: "workspaces[\(index)]")
        }
        return .init(
            physicalWindowID: physicalWindowID,
            workspaces: workspaces,
            selectedWorkspaceID: try optionalIdentifier(wire.selectedWorkspaceID, kind: "workspace", path: "selectedWorkspaceID"),
            selectedTabID: try optionalIdentifier(wire.selectedTabID, kind: "tab", path: "selectedTabID"),
            titleOverride: wire.titleOverride,
            fullscreenMode: try optionalEnum(wire.fullscreenMode, kind: "fullscreenMode", path: "fullscreenMode", type: RestoreFullscreenMode.self),
            filesPanel: try convert(wire.filesPanel)
        )
    }

    private static func convert(_ wire: TerminalRestoreWireSnapshot.Workspace, path: String) throws -> WorkspaceSnapshot {
        guard let tabs = wire.tabs else { throw RestoreSchemaFailure.fieldMissing(path: "\(path).tabs") }
        return .init(
            id: try identifier(wire.id, kind: "workspace", path: "\(path).id"),
            name: try required(wire.name, path: "\(path).name"),
            tabs: try tabs.enumerated().map { try convert($0.element, path: "\(path).tabs[\($0.offset)]") },
            selectedTabID: try optionalIdentifier(wire.selectedTabID, kind: "tab", path: "\(path).selectedTabID"),
            color: try optionalEnum(wire.color, kind: "workspaceColor", path: "\(path).color", type: RestoreColor.self),
            isCollapsed: try required(wire.isCollapsed, path: "\(path).isCollapsed"),
            defaultDirectory: wire.defaultDirectory
        )
    }

    private static func convert(_ wire: TerminalRestoreWireSnapshot.Tab, path: String) throws -> TabSnapshot {
        guard let tree = wire.tree else { throw RestoreSchemaFailure.fieldMissing(path: "\(path).tree") }
        return .init(
            id: try identifier(wire.id, kind: "tab", path: "\(path).id"),
            title: try required(wire.title, path: "\(path).title"),
            metadataTitle: wire.metadataTitle,
            titleOverride: wire.titleOverride,
            color: try optionalEnum(wire.color, kind: "tabColor", path: "\(path).color", type: RestoreColor.self),
            tree: try convert(tree, path: "\(path).tree"),
            focusedPaneID: try optionalIdentifier(wire.focusedPaneID, kind: "logicalPane", path: "\(path).focusedPaneID")
        )
    }

    private static func convert(_ wire: TerminalRestoreWireSnapshot.PaneTree, path: String) throws -> PaneTreeSnapshot {
        guard let rootIndex = wire.rootIndex else { throw RestoreSchemaFailure.fieldMissing(path: "\(path).rootIndex") }
        guard let nodes = wire.nodes else { throw RestoreSchemaFailure.fieldMissing(path: "\(path).nodes") }
        return .init(rootIndex: rootIndex, zoomedPaneID: try optionalIdentifier(wire.zoomedPaneID, kind: "logicalPane", path: "\(path).zoomedPaneID"), nodes: try nodes.enumerated().map { try convert($0.element, path: "\(path).nodes[\($0.offset)]") })
    }

    private static func convert(_ wire: TerminalRestoreWireSnapshot.Node, path: String) throws -> PaneTreeSnapshot.Node {
        let kind = try required(wire.kind, path: "\(path).kind")
        switch kind {
        case "pane":
            guard let pane = wire.pane else { throw RestoreSchemaFailure.fieldMissing(path: "\(path).pane") }
            return .pane(.init(logicalPaneID: try identifier(pane.logicalPaneID, kind: "logicalPane", path: "\(path).pane.logicalPaneID"), currentWorkingDirectory: pane.currentWorkingDirectory, rawTitle: try required(pane.rawTitle, path: "\(path).pane.rawTitle"), hasUserTitle: try required(pane.hasUserTitle, path: "\(path).pane.hasUserTitle")))
        case "split":
            return .split(direction: try enumValue(wire.direction, kind: "splitDirection", path: "\(path).direction", type: RestoreSplitDirection.self), ratio: try required(wire.ratio, path: "\(path).ratio"), first: try required(wire.first, path: "\(path).first"), second: try required(wire.second, path: "\(path).second"))
        default:
            throw RestoreSchemaFailure.enumUnknown(
                kind: "paneNodeKind",
                path: "\(path).kind")
        }
    }

    private static func convert(_ wire: TerminalRestoreWireSnapshot.FilesPanel?) throws -> RestoreFilesPanelSnapshot? {
        guard let wire else { return nil }
        return .init(visible: try required(wire.visible, path: "filesPanel.visible"), width: try required(wire.width, path: "filesPanel.width"), rootMode: try enumValue(wire.rootMode, kind: "filesPanelRootMode", path: "filesPanel.rootMode", type: RestoreFilesPanelRootMode.self), pinnedRoot: wire.pinnedRoot, showHidden: try required(wire.showHidden, path: "filesPanel.showHidden"))
    }

    private static func required<T>(_ value: T?, path: String) throws -> T {
        guard let value else { throw RestoreSchemaFailure.fieldMissing(path: path) }
        return value
    }

    private static func identifier(_ value: String?, kind: String, path: String) throws -> UUID {
        guard let value, value.utf8.count == 36, value.unicodeScalars.allSatisfy({ $0.isASCII }), let id = UUID(uuidString: value) else { throw RestoreSchemaFailure.identifierMalformed(kind: kind, path: path) }
        return id
    }

    private static func optionalIdentifier(_ value: String?, kind: String, path: String) throws -> UUID? {
        guard value != nil else { return nil }
        return try identifier(value, kind: kind, path: path)
    }

    private static func enumValue<T: RawRepresentable>(_ value: String?, kind: String, path: String, type: T.Type) throws -> T where T.RawValue == String {
        guard let value, let result = T(rawValue: value) else { throw RestoreSchemaFailure.enumUnknown(kind: kind, path: path) }
        return result
    }

    private static func optionalEnum<T: RawRepresentable>(_ value: String?, kind: String, path: String, type: T.Type) throws -> T? where T.RawValue == String {
        guard value != nil else { return nil }
        return try enumValue(value, kind: kind, path: path, type: type)
    }
}

/// A validated, passive projection. Its initializer is file-private so only this validator can mint one.
struct RestorePlan: Sendable, Equatable {
    let snapshot: TerminalRestoreSnapshot
    let warnings: [RestoreWarning]
    fileprivate init(snapshot: TerminalRestoreSnapshot, warnings: [RestoreWarning]) {
        self.snapshot = snapshot
        self.warnings = warnings
    }
}

struct PaneMaterializationRequest: Sendable, Equatable {
    let logicalPaneID: UUID
    let currentWorkingDirectory: String?
}

enum TerminalRestoreValidator {
    static func validate(_ snapshot: TerminalRestoreSnapshot) throws -> RestorePlan {
        guard !snapshot.workspaces.isEmpty else { throw RestoreValidationFailure.invariant(path: "workspaces") }
        try limit(snapshot.workspaces.count, TerminalRestoreLimits.workspacesPerWindow, path: "workspaces")
        var ids = Set<UUID>()
        try insert(snapshot.physicalWindowID, into: &ids, path: "physicalWindowID")
        var paneTotal = 0
        var tabTotal = 0
        var nodeTotal = 0
        var warnings: [RestoreWarning] = []
        var normalized = snapshot
        for workspaceIndex in normalized.workspaces.indices {
            var workspace = normalized.workspaces[workspaceIndex]
            let workspacePath = "workspaces[\(workspaceIndex)]"
            try insert(workspace.id, into: &ids, path: "\(workspacePath).id")
            guard !workspace.tabs.isEmpty else { throw RestoreValidationFailure.invariant(path: "\(workspacePath).tabs") }
            try validationAdd(workspace.tabs.count, to: &tabTotal, maximum: TerminalRestoreLimits.tabsPerWindow, path: "tabs")
            for tabIndex in workspace.tabs.indices {
                let tabPath = "\(workspacePath).tabs[\(tabIndex)]"
                var tab = workspace.tabs[tabIndex]
                try insert(tab.id, into: &ids, path: "\(tabPath).id")
                let result = try validate(tree: tab.tree, path: "\(tabPath).tree", ids: &ids)
                try validationAdd(result.panes, to: &paneTotal, maximum: TerminalRestoreLimits.panesPerWindow, path: "panes")
                try validationAdd(result.nodes, to: &nodeTotal, maximum: TerminalRestoreLimits.recordsPerWindow, path: "nodes")
                if let focused = tab.focusedPaneID, !result.paneIDs.contains(focused) {
                    tab.focusedPaneID = result.firstPane
                    warnings.append(.normalizedFocus(workspaceIndex: workspaceIndex, tabIndex: tabIndex))
                }
                if let zoom = tab.tree.zoomedPaneID, !result.paneIDs.contains(zoom) {
                    throw RestoreValidationFailure.invariant(path: "\(tabPath).tree.zoomedPaneID")
                }
                workspace.tabs[tabIndex] = tab
            }
            if workspace.selectedTabID == nil || !workspace.tabs.contains(where: { $0.id == workspace.selectedTabID }) {
                workspace.selectedTabID = workspace.tabs[0].id
                warnings.append(.normalizedWorkspaceSelection(workspaceIndex: workspaceIndex))
            }
            normalized.workspaces[workspaceIndex] = workspace
        }
        if normalized.selectedWorkspaceID == nil {
            normalized.selectedWorkspaceID = normalized.workspaces[0].id
            normalized.selectedTabID = normalized.workspaces[0].tabs[0].id
            warnings.append(.normalizedWindowSelection)
        } else if let selected = normalized.selectedWorkspaceID, !normalized.workspaces.contains(where: { $0.id == selected }) {
            normalized.selectedWorkspaceID = normalized.workspaces[0].id
            normalized.selectedTabID = normalized.workspaces[0].tabs[0].id
            warnings.append(.normalizedWindowSelection)
        }
        if normalized.selectedTabID == nil {
            let selectedWorkspace = normalized.workspaces.first { $0.id == normalized.selectedWorkspaceID }
            normalized.selectedTabID = selectedWorkspace?.tabs[0].id
            warnings.append(.normalizedWindowSelection)
        } else if let selectedTab = normalized.selectedTabID {
            let selectedWorkspace = normalized.selectedWorkspaceID.flatMap { id in normalized.workspaces.first(where: { $0.id == id }) }
            if selectedWorkspace?.tabs.contains(where: { $0.id == selectedTab }) != true {
                normalized.selectedTabID = selectedWorkspace?.tabs[0].id ?? normalized.workspaces[0].tabs[0].id
                warnings.append(.normalizedWindowSelection)
            }
        }
        try validate(filesPanel: normalized.filesPanel)
        return RestorePlan(snapshot: normalized, warnings: warnings)
    }

    private static func validate(tree: PaneTreeSnapshot, path: String, ids: inout Set<UUID>) throws -> (panes: Int, nodes: Int, paneIDs: Set<UUID>, firstPane: UUID) {
        guard !tree.nodes.isEmpty else { throw RestoreValidationFailure.invariant(path: "\(path).nodes") }
        try limit(tree.nodes.count, TerminalRestoreLimits.recordsPerTab, path: "\(path).nodes")
        guard tree.nodes.indices.contains(tree.rootIndex) else { throw RestoreValidationFailure.invariant(path: "\(path).rootIndex") }
        var parents = Array(repeating: 0, count: tree.nodes.count)
        var paneIDs = Set<UUID>()
        for (index, node) in tree.nodes.enumerated() {
            switch node {
            case let .pane(pane):
                try insert(pane.logicalPaneID, into: &ids, path: "\(path).nodes[\(index)].pane.logicalPaneID")
                paneIDs.insert(pane.logicalPaneID)
            case let .split(_, ratio, first, second):
                guard ratio.isFinite, ratio > 0, ratio < 1 else { throw RestoreValidationFailure.invalidValue(path: "\(path).nodes[\(index)].ratio") }
                guard tree.nodes.indices.contains(first), tree.nodes.indices.contains(second), first != second else { throw RestoreValidationFailure.invariant(path: "\(path).nodes[\(index)]") }
                parents[first] += 1
                parents[second] += 1
            }
        }
        guard parents[tree.rootIndex] == 0 else { throw RestoreValidationFailure.invariant(path: "\(path).rootIndex") }
        guard parents.enumerated().allSatisfy({ $0.offset == tree.rootIndex ? $0.element == 0 : $0.element == 1 }) else { throw RestoreValidationFailure.invariant(path: "\(path).parents") }
        var visited = Set<Int>()
        var stack: [(Int, Int)] = [(tree.rootIndex, 1)]
        var firstPane: UUID?
        while let (index, depth) = stack.popLast() {
            guard visited.insert(index).inserted else { throw RestoreValidationFailure.invariant(path: "\(path).cycle") }
            guard depth <= TerminalRestoreLimits.treeDepth else { throw RestoreValidationFailure.budgetExceeded(path: "\(path).depth") }
            switch tree.nodes[index] {
            case let .pane(pane): firstPane = firstPane ?? pane.logicalPaneID
            case let .split(_, _, first, second):
                stack.append((second, depth + 1)); stack.append((first, depth + 1))
            }
        }
        guard visited.count == tree.nodes.count, let firstPane else { throw RestoreValidationFailure.invariant(path: "\(path)") }
        try limit(paneIDs.count, TerminalRestoreLimits.panesPerTab, path: "\(path).panes")
        return (paneIDs.count, tree.nodes.count, paneIDs, firstPane)
    }

    private static func validate(filesPanel: RestoreFilesPanelSnapshot?) throws {
        guard let filesPanel else { return }
        guard filesPanel.width.isFinite, (220...480).contains(filesPanel.width) else { throw RestoreValidationFailure.invalidValue(path: "filesPanel.width") }
        switch filesPanel.rootMode {
        case .followPWD: guard filesPanel.pinnedRoot == nil else { throw RestoreValidationFailure.invariant(path: "filesPanel.pinnedRoot") }
        case .pinned: guard let root = filesPanel.pinnedRoot, !root.isEmpty else { throw RestoreValidationFailure.invariant(path: "filesPanel.pinnedRoot") }
        }
    }
}

private func boundedString(_ value: String?, limit: Int, path: String) throws {
    guard value.map({ $0.utf8.count <= limit }) ?? true else { throw RestoreDecodeFailure.budgetExceeded(path: path) }
}
private func boundedUUID(_ value: String?, path: String) throws {
    guard value.map({ $0.utf8.count <= 36 }) ?? true else {
        throw RestoreDecodeFailure.budgetExceeded(path: path)
    }
}
private func boundedEnum(_ value: String?, path: String) throws { try boundedString(value, limit: TerminalRestoreLimits.enumBytes, path: path) }
private func count(_ value: Int, maximum: Int, path: String) throws { guard value <= maximum else { throw RestoreDecodeFailure.budgetExceeded(path: path) } }
private func add(_ value: Int, to total: inout Int, maximum: Int, path: String) throws {
    let (next, overflow) = total.addingReportingOverflow(value)
    guard !overflow else { throw RestoreDecodeFailure.budgetOverflow(path: path) }
    guard next <= maximum else { throw RestoreDecodeFailure.budgetExceeded(path: path) }
    total = next
}
private func validationAdd(_ value: Int, to total: inout Int, maximum: Int, path: String) throws {
    let (next, overflow) = total.addingReportingOverflow(value)
    guard !overflow else { throw RestoreValidationFailure.budgetOverflow(path: path) }
    guard next <= maximum else { throw RestoreValidationFailure.budgetExceeded(path: path) }
    total = next
}
private func limit(_ value: Int, _ maximum: Int, path: String) throws { guard value <= maximum else { throw RestoreValidationFailure.budgetExceeded(path: path) } }
private func insert(_ id: UUID, into ids: inout Set<UUID>, path: String) throws { guard ids.insert(id).inserted else { throw RestoreValidationFailure.duplicateIdentifier(path: path) } }

@MainActor
enum TerminalRestoreProjection {
    static func makeWire(from controller: TerminalController) throws -> TerminalRestoreWireSnapshot {
        let snapshot = controller.workspaceStore.snapshot
        try count(snapshot.workspaces.count, maximum: TerminalRestoreLimits.workspacesPerWindow, path: "workspaces")
        var eligible: [TerminalRestoreWireSnapshot.Workspace] = []
        var totalTabs = 0
        var totalPanes = 0
        var totalNodes = 0
        for workspace in snapshot.workspaces {
            var tabs: [TerminalRestoreWireSnapshot.Tab] = []
            for session in workspace.tabs where session.isRestorationEligible {
                try count(tabs.count + 1, maximum: TerminalRestoreLimits.tabsPerWindow, path: "tabs")
                let tab = try makeTab(session, presentedID: controller.presentedSessionID, controller: controller)
                try add(1, to: &totalTabs, maximum: TerminalRestoreLimits.tabsPerWindow, path: "tabs")
                try add(tab.tree?.nodes?.count ?? 0, to: &totalNodes,
                        maximum: TerminalRestoreLimits.recordsPerWindow, path: "tree.nodes")
                let paneCount = tab.tree?.nodes?.reduce(into: 0) { count, node in
                    if node.kind == "pane" { count += 1 }
                } ?? 0
                try add(paneCount, to: &totalPanes, maximum: TerminalRestoreLimits.panesPerWindow, path: "tree.panes")
                tabs.append(tab)
            }
            guard !tabs.isEmpty else { continue }
            let selected = workspace.selectedTabID.flatMap { id in tabs.contains(where: { $0.id == id.uuidString }) ? id.uuidString : tabs[0].id }
            eligible.append(.init(id: workspace.id.uuidString, name: workspace.name, tabs: tabs, selectedTabID: selected,
                         color: RestoreColor.allCases.indices.contains(workspace.color.rawValue) ? RestoreColor.allCases[workspace.color.rawValue].rawValue : nil, isCollapsed: workspace.isCollapsed,
                         defaultDirectory: workspace.defaultDirectory))
        }
        let selectedWorkspaceID = snapshot.selection.workspaceID
        let selectedWorkspace = eligible.contains(where: { $0.id == selectedWorkspaceID.uuidString })
            ? selectedWorkspaceID.uuidString
            : eligible.first?.id
        let selectedTab = eligible.first(where: { $0.id == selectedWorkspace })?.selectedTabID
        let files = controller.filesPanelController?.presentation.persisted
        let fullscreenMode = controller.fullscreenStyle.flatMap {
            $0.isFullscreen && $0.fullscreenMode != .native
                ? $0.fullscreenMode.rawValue
                : nil
        }
        let wire = TerminalRestoreWireSnapshot(physicalWindowID: controller.physicalUUID.uuidString, workspaces: eligible,
                     selectedWorkspaceID: selectedWorkspace, selectedTabID: selectedTab,
                     titleOverride: controller.titleOverride,
                     fullscreenMode: fullscreenMode,
                     filesPanel: files.map { .init(visible: $0.visible, width: $0.width, rootMode: $0.rootMode.rawValue, pinnedRoot: $0.pinnedRoot, showHidden: $0.showHidden) })
        try wire.validateBounds()
        return wire
    }

    private static func makeTab(_ session: TerminalSessionState, presentedID: UUID?, controller: TerminalController) throws -> TerminalRestoreWireSnapshot.Tab {
        let tree = session.id == presentedID ? controller.surfaceTree : session.surfaceTree
        let focused = session.id == presentedID ? controller.focusedSurface?.logicalPaneID : session.focusedSurfaceID.flatMap { runtimeID in tree.first(where: { $0.id == runtimeID })?.logicalPaneID }
        let color = session.tabColor ?? (session.id == presentedID
            ? (controller.window as? TerminalWindow).flatMap { RestoreColor.allCases.indices.contains($0.tabColor.rawValue) ? RestoreColor.allCases[$0.tabColor.rawValue].rawValue : nil }
            : nil)
        // Session.title includes the bell decoration used by the tab UI; the pane title is
        // the raw terminal metadata and is the only title persisted in the archive.
        return .init(id: session.id.uuidString, title: tree.first?.title, metadataTitle: nil, titleOverride: session.titleOverride,
                     color: color, tree: try makeTree(tree), focusedPaneID: focused?.uuidString)
    }

    private static func makeTree(_ tree: SplitTree<Ghostty.SurfaceView>) throws -> TerminalRestoreWireSnapshot.PaneTree {
        var nodes: [TerminalRestoreWireSnapshot.Node] = []
        var panes = 0
        func append(_ node: SplitTree<Ghostty.SurfaceView>.Node, depth: Int) throws -> Int {
            try count(depth, maximum: TerminalRestoreLimits.treeDepth, path: "tree.depth")
            let index = nodes.count
            try count(nodes.count + 1, maximum: TerminalRestoreLimits.recordsPerTab, path: "tree.nodes")
            nodes.append(.init(kind: nil, pane: nil, direction: nil, ratio: nil, first: nil, second: nil))
            switch node {
            case let .leaf(view):
                try count(panes + 1, maximum: TerminalRestoreLimits.panesPerTab, path: "tree.panes")
                panes += 1
                nodes[index] = .init(
                    kind: "pane",
                    pane: .init(
                        logicalPaneID: view.logicalPaneID.uuidString,
                        currentWorkingDirectory: view.pwd,
                        rawTitle: view.title,
                        hasUserTitle: view.hasUserSetTitle),
                    direction: nil,
                    ratio: nil,
                    first: nil,
                    second: nil)
            case let .split(split):
                let first = try append(split.left, depth: depth + 1)
                let second = try append(split.right, depth: depth + 1)
                nodes[index] = .init(kind: "split", pane: nil, direction: split.direction == .horizontal ? "horizontal" : "vertical", ratio: split.ratio, first: first, second: second)
            }
            return index
        }
        let root = try tree.root.map { try append($0, depth: 1) } ?? 0
        let zoom = tree.zoomed.flatMap { node -> String? in
            guard case let .leaf(view) = node else { return nil }
            return view.logicalPaneID.uuidString
        }
        return .init(rootIndex: root, zoomedPaneID: zoom, nodes: nodes)
    }
}

@MainActor
final class TerminalRestoreMaterializationTransaction {
    private enum State: Equatable { case staged, committed, rolledBack }
    let plan: RestorePlan
    private(set) var materializationWarnings: [RestoreWarning]
    private let ghostty: Ghostty.App
    private let graph: TerminalControllerGraphFactory.InitialGraph
    private let baselineControllerIDs: Set<ObjectIdentifier>
    private var surfaces: [Ghostty.SurfaceView]
    private var state: State = .staged
    private weak var controller: TerminalController?

    fileprivate init(plan: RestorePlan, ghostty: Ghostty.App, graph: TerminalControllerGraphFactory.InitialGraph, surfaces: [Ghostty.SurfaceView], materializationWarnings: [RestoreWarning]) {
        self.plan = plan
        self.ghostty = ghostty
        self.graph = graph
        self.baselineControllerIDs = Set(
            TerminalController.all.map(ObjectIdentifier.init))
        self.surfaces = surfaces
        self.materializationWarnings = materializationWarnings
    }

    func commit(
        beforePublication: () throws -> Void = {}
    ) throws -> TerminalController {
        guard state == .staged else { throw RestoreMaterializationFailure.publication }
        let controller = TerminalController(
            ghostty,
            graph: graph,
            restoredPhysicalUUID: plan.snapshot.physicalWindowID,
            deferredPublication: true)
        self.controller = controller
        do {
            controller.loadWindow()
            guard let window = controller.window as? TerminalWindow else {
                throw RestoreMaterializationFailure.windowLoad
            }
            window.orderOut(nil)
            hydrate(controller, window: window)
            try beforePublication()
            try controller.commitDeferredRestorationPublication()
            state = .committed
            if let fullscreen = plan.snapshot.fullscreenMode, fullscreen != .native {
                DispatchQueue.main.async { [weak controller] in
                    let mode: FullscreenMode = switch fullscreen {
                    case .native: .native
                    case .nonNative: .nonNative
                    case .nonNativeVisibleMenu: .nonNativeVisibleMenu
                    case .nonNativePaddedNotch: .nonNativePaddedNotch
                    }
                    controller?.toggleFullscreen(mode: mode)
                }
            }
            return controller
        } catch {
            guard rollback() else {
                throw RestoreMaterializationFailure.explicitClose
            }
            throw error
        }
    }

    @discardableResult
    func rollback() -> Bool {
        guard state == .staged else { return true }
        var cleanupVerified = true
        for surface in surfaces {
            guard let model = surface.surfaceModel, model.close() else {
                cleanupVerified = false
                continue
            }
        }
        surfaces.removeAll()
        weak var stagedWindow = controller?.window
        stagedWindow?.orderOut(nil)
        if let controller, !controller.rollbackDeferredRestorationPublication() {
            cleanupVerified = false
        }
        controller?.close()
        let controllerIDs = Set(
            TerminalController.all.map(ObjectIdentifier.init))
        if stagedWindow?.isVisible == true ||
            controllerIDs != baselineControllerIDs {
            cleanupVerified = false
        }
        state = .rolledBack
        return cleanupVerified
    }

    private func hydrate(_ controller: TerminalController, window: TerminalWindow) {
        controller.titleOverride = plan.snapshot.titleOverride
        if let files = plan.snapshot.filesPanel {
            controller.stageFilesPanel(.init(
                visible: files.visible, width: files.width,
                rootMode: files.rootMode == .pinned ? .pinned : .followPWD,
                pinnedRoot: files.pinnedRoot, showHidden: files.showHidden))
        }
        guard
            let workspaceID = plan.snapshot.selectedWorkspaceID,
            let workspace = plan.snapshot.workspaces.first(where: { $0.id == workspaceID }),
            let tabID = plan.snapshot.selectedTabID ?? workspace.selectedTabID,
            let tab = workspace.tabs.first(where: { $0.id == tabID }),
            let session = controller.workspaceStore.session(forTabID: tab.id),
            let focusID = tab.focusedPaneID,
            let view = session.surfaceTree.first(where: { $0.logicalPaneID == focusID })
        else { return }
        controller.focusedSurface = view
        if !window.makeFirstResponder(view) {
            // The window is loaded and ordered out; failure is a truthful non-fatal warning.
            materializationWarnings.append(.focusAttachmentFailed)
        }
    }
}

@MainActor
enum TerminalRestoreMaterializer {
    typealias PaneFactory = @MainActor (
        ghostty_app_t,
        PaneMaterializationRequest
    ) throws -> Ghostty.SurfaceView

    static func materialize(
        _ plan: RestorePlan,
        ghostty: Ghostty.App,
        factory: PaneFactory = makeProductionSurface
    ) throws -> TerminalRestoreMaterializationTransaction {
        guard let app = ghostty.app else { throw RestoreMaterializationFailure.surfaceFactory }
        var made: [Ghostty.SurfaceView] = []
        var warnings: [RestoreWarning] = []
        do {
            var workspaces: [WorkspaceSession] = []
            for workspace in plan.snapshot.workspaces {
                var sessions: [TerminalSessionState] = []
                for tab in workspace.tabs {
                    let tree = try build(
                        tab.tree,
                        app: app,
                        factory: factory,
                        surfaces: &made,
                        warnings: &warnings)
                    let session = TerminalSessionState(id: tab.id, surfaceTree: tree)
                    session.title = tab.title; session.titleOverride = tab.titleOverride
                    session.tabColor = tab.color?.rawValue
                    session.focusedSurfaceID = tab.focusedPaneID.flatMap { logical in tree.first(where: { $0.logicalPaneID == logical })?.id }
                    sessions.append(session)
                }
                workspaces.append(.init(id: workspace.id, name: workspace.name, tabs: sessions,
                                        selectedTabID: workspace.selectedTabID ?? sessions[0].id,
                                        color: color(workspace.color), isCollapsed: workspace.isCollapsed,
                                        defaultDirectory: workspace.defaultDirectory))
            }
            let selectedWorkspace = plan.snapshot.selectedWorkspaceID ?? workspaces[0].id
            let selectedTab = plan.snapshot.selectedTabID
                ?? workspaces.first(where: { $0.id == selectedWorkspace })?.tabs[0].id
                ?? workspaces[0].tabs[0].id
            guard let graph = TerminalControllerGraphFactory.makeFromWorkspaces(workspaces, selection: .init(workspaceID: selectedWorkspace, tabID: selectedTab)) else {
                throw RestoreMaterializationFailure.publication
            }
            return .init(plan: plan, ghostty: ghostty, graph: graph, surfaces: made, materializationWarnings: warnings)
        } catch {
            var cleanupVerified = true
            for surface in made {
                guard let model = surface.surfaceModel, model.close() else {
                    cleanupVerified = false
                    continue
                }
            }
            if !cleanupVerified {
                throw RestoreMaterializationFailure.explicitClose
            }
            throw error
        }
    }

    private static func makeProductionSurface(
        _ app: ghostty_app_t,
        request: PaneMaterializationRequest
    ) throws -> Ghostty.SurfaceView {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = request.currentWorkingDirectory
        do {
            return try Ghostty.SurfaceView.makeColdRestored(
                app,
                logicalPaneID: request.logicalPaneID,
                baseConfig: config)
        } catch Ghostty.SurfaceView.ColdRestoreError.policyMismatch {
            throw RestoreMaterializationFailure.coldPolicyMismatch
        } catch {
            throw RestoreMaterializationFailure.surfaceFactory
        }
    }

    private static func build(
        _ tree: PaneTreeSnapshot,
        app: ghostty_app_t,
        factory: PaneFactory,
        surfaces: inout [Ghostty.SurfaceView],
        warnings: inout [RestoreWarning]
    ) throws -> SplitTree<Ghostty.SurfaceView> {
        var zoomed: SplitTree<Ghostty.SurfaceView>.Node?
        func node(_ index: Int) throws -> SplitTree<Ghostty.SurfaceView>.Node {
            switch tree.nodes[index] {
            case let .pane(pane):
                var workingDirectory: String?
                if let cwd = pane.currentWorkingDirectory {
                    var directory = ObjCBool(false)
                    if FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue {
                        workingDirectory = cwd
                    } else {
                        warnings.append(.currentWorkingDirectoryFallback)
                    }
                }
                let surface = try factory(
                    app,
                    .init(
                        logicalPaneID: pane.logicalPaneID,
                        currentWorkingDirectory: workingDirectory))
                surface.restoreTitleMetadata(
                    pane.rawTitle,
                    isUserSet: pane.hasUserTitle)
                surfaces.append(surface)
                let leaf = SplitTree<Ghostty.SurfaceView>.Node.leaf(view: surface)
                if pane.logicalPaneID == tree.zoomedPaneID { zoomed = leaf }
                return leaf
            case let .split(direction, ratio, first, second):
                return .split(.init(direction: direction == .horizontal ? .horizontal : .vertical, ratio: ratio, left: try node(first), right: try node(second)))
            }
        }
        let root = try node(tree.rootIndex)
        return .init(root: root, zoomed: zoomed)
    }

    private static func color(_ color: RestoreColor?) -> TerminalTabColor {
        guard let color else { return .none }
        return TerminalTabColor(rawValue: RestoreColor.allCases.firstIndex(of: color) ?? 0) ?? .none
    }
}
