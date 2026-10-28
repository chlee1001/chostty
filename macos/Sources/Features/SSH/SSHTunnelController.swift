import Combine
import Foundation

/// Joins saved tunnel definitions with the running tunnel manager. Views and
/// commands go through here so start rules live in one place.
@MainActor
final class SSHTunnelController: ObservableObject {
    static let missingHostMessage = "This tunnel's host is no longer in your SSH configuration."

    let manager: SSHTunnelManager
    @Published private(set) var definitions: [SSHTunnelDefinition] = []
    private let availableHosts: () -> [SSHHostReference]
    private var managerChanges: AnyCancellable?

    init(manager: SSHTunnelManager, availableHosts: @escaping () -> [SSHHostReference]) {
        self.manager = manager
        self.availableHosts = availableHosts
        managerChanges = manager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func apply(_ metadata: SSHHostMetadataFile) {
        definitions = metadata.tunnels
    }

    func definition(_ id: UUID) -> SSHTunnelDefinition? {
        definitions.first { $0.id == id }
    }

    /// Why a tunnel cannot start now, or nil when it can.
    func startBlocker(for definition: SSHTunnelDefinition) -> String? {
        availableHosts().contains(definition.host) ? nil : Self.missingHostMessage
    }

    func isRunning(_ id: UUID) -> Bool {
        manager.isRunning(id)
    }

    func start(_ id: UUID) {
        guard let definition = definition(id), startBlocker(for: definition) == nil else { return }
        manager.start(definition)
    }

    func stop(_ id: UUID) {
        manager.stop(id)
    }

    /// Running tunnels that would lose their host if this managed host went away.
    func runningTunnels(forManagedHost hostID: UUID) -> [SSHTunnelDefinition] {
        definitions.filter { $0.host.source == .managed(hostID: hostID) && manager.isRunning($0.id) }
    }

    func stopNow(_ ids: [UUID]) -> Bool {
        manager.stopNow(ids)
    }

    static func status(for phase: SSHTunnelPhase) -> String {
        switch phase {
        case .stopped: "stopped"
        case .starting: "starting"
        case .authenticating: "waiting for authentication"
        case .ready: "ready"
        case .runningUnconfirmed: "running, unconfirmed"
        case .stopping: "stopping"
        case .failed(let failure): failure.message
        }
    }

    static func specification(of definition: SSHTunnelDefinition) -> String {
        let flag = switch definition.kind {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
        let bind = "\(definition.bindAddress):\(definition.bindPort)"
        guard let host = definition.targetHost, let port = definition.targetPort else {
            return "\(flag) \(bind) · \(definition.host.alias)"
        }
        return "\(flag) \(bind) → \(host):\(port) · \(definition.host.alias)"
    }
}
