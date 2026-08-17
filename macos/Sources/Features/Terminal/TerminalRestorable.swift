import Cocoa

protocol TerminalRestorable: Codable {
    static var selfKey: String { get }
    static var versionKey: String { get }
    static var version: Int { get }
    static var minimumVersion: Int { get }
    init(copy other: Self)
    var baseConfig: Ghostty.SurfaceConfiguration? { get }
}

extension TerminalRestorable {
    static var minimumVersion: Int { version }
    static var selfKey: String { "state" }
    static var versionKey: String { "version" }
    var baseConfig: Ghostty.SurfaceConfiguration? { nil }

    init?(coder decoder: NSCoder) {
        let version = decoder.decodeInteger(forKey: Self.versionKey)
        guard version >= Self.minimumVersion, version <= Self.version else { return nil }
        guard let bridge = decoder.decodeObject(of: CodableBridge<Self>.self, forKey: Self.selfKey) else { return nil }
        self.init(copy: bridge.value)
    }

    func encode(with coder: NSCoder) throws {
        let bridge = try CodableBridge(self)
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(bridge, forKey: Self.selfKey)
        if let error = coder.error {
            throw error
        }
    }
}

/// The v9 ordinary-window archive contains only passive values. It never decodes a view.
final class TerminalRestorableState: TerminalRestorable {
    static var version: Int { 9 }
    static var minimumVersion: Int { 9 }

    let wire: TerminalRestoreWireSnapshot

    init(wire: TerminalRestoreWireSnapshot) { self.wire = wire }

    required init(copy other: TerminalRestorableState) { wire = other.wire }
    init(from decoder: any Decoder) throws { wire = try TerminalRestoreWireSnapshot(from: decoder) }
    func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }

    static func decodeV9(from decoder: NSCoder) throws -> TerminalRestorableState {
        guard decoder.containsValue(forKey: selfKey) else {
            throw CodableBridgeError.missingData
        }
        guard let bridge = decoder.decodeObject(
            of: CodableBridge<TerminalRestorableState>.self,
            forKey: selfKey)
        else {
            throw decoder.error ?? CodableBridgeError.corruptData
        }
        return .init(copy: bridge.value)
    }

    func restorePlan() throws -> RestorePlan {
        try wire.validateBounds()
        return try TerminalRestoreValidator.validate(
            TerminalRestoreSchemaDecoder.convert(wire))
    }

    func withValidatedPlan<Result>(
        _ materialize: (RestorePlan) throws -> Result
    ) throws -> Result {
        try materialize(restorePlan())
    }
}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case decode(RestoreDecodeFailure)
    case materialization(RestoreMaterializationFailure)
    case windowDidNotLoad
}

/// AppKit entry point. Invalid archives have no fallback path and therefore create no surface.
@MainActor
class TerminalWindowRestoration: NSObject, NSWindowRestoration {
    /// Injection point for the tests that must prove a rejected archive never
    /// reaches a pane factory. Debug-only so the shipping entry point has no
    /// substitutable factory at all.
    #if DEBUG
    static var paneFactoryOverride:
        TerminalRestoreMaterializer.PaneFactory?
    #endif

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        let appDelegate = NSApp.delegate as? AppDelegate
        let token = appDelegate?.beginOrdinaryRestoreAttempt()
        var completionSent = false
        func finish(_ window: NSWindow?, _ error: Error?, _ outcome: RestoreAttemptCoordinator.Outcome) {
            guard !completionSent else { return }
            completionSent = true
            guard let appDelegate, let token else {
                completionHandler(window, error)
                return
            }
            if !appDelegate.completeOrdinaryRestoreAttempt(token, outcome: outcome) {
                AppDelegate.logger.error("ordinary restoration completion diverged")
            }
            completionHandler(window, error)
        }
        guard identifier == .init(String(describing: Self.self)) else {
            finish(nil, TerminalRestoreError.identifierUnknown, .failure(.archiveRejected)); return
        }
        guard let appDelegate else {
            completionHandler(nil, TerminalRestoreError.delegateInvalid); return
        }
        guard appDelegate.ghostty.config.windowSaveState != "never" else {
            finish(nil, nil, .failure(.archiveRejected)); return
        }
        let version = state.decodeInteger(forKey: TerminalRestorableState.versionKey)
        guard version == TerminalRestorableState.version else {
            finish(nil, TerminalRestoreError.stateDecodeFailed,
                   .failure(version == 8 ? .v8Discarded : .archiveRejected)); return
        }
        let archived: TerminalRestorableState
        do {
            archived = try TerminalRestorableState.decodeV9(from: state)
        } catch {
            finish(
                nil,
                TerminalRestoreError.stateDecodeFailed,
                .failure(.decodeRejected))
            return
        }
        do {
            let transaction = try archived.withValidatedPlan {
                #if DEBUG
                if let factory = paneFactoryOverride {
                    return try TerminalRestoreMaterializer.materialize(
                        $0,
                        ghostty: appDelegate.ghostty,
                        factory: factory)
                }
                #endif
                return try TerminalRestoreMaterializer.materialize(
                    $0,
                    ghostty: appDelegate.ghostty)
            }
            let controller = try transaction.commit()
            guard let window = controller.window else { throw TerminalRestoreError.windowDidNotLoad }
            finish(window, nil, .success(transaction.materializationWarnings))
        } catch let error as TerminalRestoreError {
            finish(nil, error, .failure(.archiveRejected))
        } catch let error as RestoreDecodeFailure {
            finish(
                nil,
                TerminalRestoreError.decode(error),
                .failure(.decodeRejected))
        } catch let error as RestoreSchemaFailure {
            finish(nil, error, .failure(.schemaRejected))
        } catch let error as RestoreValidationFailure {
            finish(nil, error, .failure(.validationRejected))
        } catch let error as RestoreMaterializationFailure {
            let code: TerminalRestoreReportCode = switch error {
            case .explicitClose: .cleanupFailed
            case .publication: .publicationFailed
            default: .materializationFailed
            }
            finish(nil, TerminalRestoreError.materialization(error), .failure(code))
        } catch {
            finish(nil, TerminalRestoreError.stateDecodeFailed, .failure(.archiveRejected))
        }
    }

}
