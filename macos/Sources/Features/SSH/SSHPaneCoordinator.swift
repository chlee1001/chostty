import Combine
import Foundation

@MainActor
final class SSHPaneCoordinator {
    private let catalog: SSHHostCatalog
    private let authorization: SSHAskpassAuthorization?
    private let brokerAvailable: () -> Bool
    private let channels = NSMapTable<NSUUID, SSHPaneChannel>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private var answered: [UUID: Int] = [:]
    private var initialRequests: Set<UUID> = []
    private var subscription: AnyCancellable?

    init(catalog: SSHHostCatalog, authorization: SSHAskpassAuthorization?, brokerAvailable: @escaping () -> Bool) {
        self.catalog = catalog
        self.authorization = authorization
        self.brokerAvailable = brokerAvailable
        subscription = catalog.$snapshot.sink { [weak self] snapshot in
            self?.updateEligibility(snapshot)
        }
    }

    func register(_ channel: SSHPaneChannel) {
        channels.setObject(channel, forKey: channel.launchID as NSUUID)
        let launchID = channel.launchID
        channel.setCoordinator(self, onDispose: { [authorization] in
            authorization?.revoke(launchID: launchID)
        })
    }

    func supervisorReady(launchID: UUID) {
        guard let channel = channels.object(forKey: launchID as NSUUID), channel.autoConnect,
              initialRequests.insert(launchID).inserted else { return }
        requestConnect(launchID: launchID)
    }

    func observedConnection(launchID: UUID, sequence: Int) {
        authorization?.observed(launchID: launchID, sequence: sequence)
    }

    func requestConnect(launchID: UUID) {
        guard let channel = channels.object(forKey: launchID as NSUUID), channel.canRequestConnect else { return }
        let sequence = channel.lastStateSequence
        guard answered[launchID] != sequence else { return }
        answered[launchID] = sequence
        let commandSequence = channel.reserveCommandSequence()
        let revalidation = catalog.revalidation(for: channel.binding.reference)
        logRevalidation(revalidation)
        switch revalidation {
        case .valid:
            channel.setReconnectBlock(nil)
            guard let authorization else {
                channel.sendConnect(sequence: commandSequence, token: nil)
                return
            }
            authorization.prepare(
                reference: channel.binding.reference,
                launchID: launchID,
                sequence: commandSequence,
                supervisor: channel.pinnedSupervisor(),
                brokerAvailable: brokerAvailable()
            ) { [weak self, weak channel] token in
                Task { @MainActor [weak self, weak channel] in
                    guard let self, let channel, channel.commandSequence == commandSequence else { return }
                    let revalidation = self.catalog.revalidation(for: channel.binding.reference)
                    self.logRevalidation(revalidation)
                    switch revalidation {
                    case .valid:
                        channel.sendConnect(sequence: commandSequence, token: token)
                    case .blocked(let reason):
                        authorization.revoke(launchID: launchID)
                        channel.setReconnectBlock(reason)
                        channel.sendDeny(reason, sequence: commandSequence)
                    }
                }
            }
        case .blocked(let reason):
            authorization?.revoke(launchID: launchID)
            channel.setReconnectBlock(reason)
            channel.sendDeny(reason, sequence: commandSequence)
        }
    }

    private func updateEligibility(_ snapshot: SSHConfigScanResult) {
        let keys = channels.keyEnumerator().allObjects.compactMap { $0 as? NSUUID }
        for key in keys {
            guard let channel = channels.object(forKey: key) else {
                answered.removeValue(forKey: key as UUID)
                initialRequests.remove(key as UUID)
                authorization?.revoke(launchID: key as UUID)
                channels.removeObject(forKey: key)
                continue
            }
            let reference = channel.binding.reference
            let block: SSHReconnectBlock?
            switch catalog.revalidation(for: reference, in: snapshot) {
            case .valid: block = nil
            case .blocked(let reason): block = reason
            }
            channel.setReconnectBlock(block)
            if block != nil {
                authorization?.revoke(launchID: key as UUID)
            }
        }
    }

    private func logRevalidation(_ revalidation: SSHHostRevalidation) {
        let result: String
        let value: String
        switch revalidation {
        case .valid:
            result = "ok"
            value = "none"
        case .blocked(let reason):
            result = "denied"
            switch reason {
            case .hostRemoved: value = "hostRemoved"
            case .aliasInvalid: value = "aliasInvalid"
            case .configUnreadable: value = "configUnreadable"
            }
        }
        SSHLog.logger.notice(
            "connect.revalidated result=\(result, privacy: .public) reason=\(value, privacy: .public)")
    }
}
