import AppKit
import Combine
import Foundation

@MainActor
final class SSHServices: ObservableObject {
    static let recentHostLimit = 8
    let catalog: SSHHostCatalog
    let resolver = SSHResolver()
    let loginEnvironment = SSHLoginEnvironmentProvider()
    let paths: SSHPaths
    let secretStore: any SSHSecretStore
    @Published private(set) var recentReferences: [SSHHostReference] = []
    @Published private(set) var passwordWarnings: [UUID: String] = [:]
    lazy var connectService = SSHConnectService(services: self)
    lazy var tunnels = SSHTunnelController(
        manager: SSHTunnelManager(
            paths: paths, loginEnvironment: loginEnvironment, authentication: tunnelAuthorization),
        availableHosts: { [weak self] in self?.catalog.snapshot.entries.map(\.reference) ?? [] })
    private var askpassBroker: SSHAskpassBroker?
    private let tunnelAuthorization: SSHTunnelAskpassAuthorization?
    private var tunnelPrompts: [UUID: SSHTunnelPromptSheet] = [:]
    private lazy var authorization = SSHAskpassAuthorization(
        paths: paths,
        secretStore: secretStore,
        warning: { [weak self] hostID, warning in
            Task { @MainActor [weak self] in
                self?.setPasswordWarning(warning, for: hostID)
            }
        })
    lazy var coordinator = SSHPaneCoordinator(
        catalog: catalog,
        authorization: authorization,
        brokerAvailable: { [weak self] in self?.askpassBroker?.isAvailable == true })

    var askpassSocketURL: URL? {
        guard let askpassBroker, askpassBroker.isAvailable else { return nil }
        return askpassBroker.socketURL
    }

    init(
        paths: SSHPaths,
        secretStore: any SSHSecretStore = KeychainSSHSecretStore()
    ) {
        self.paths = paths
        self.secretStore = secretStore
        self.catalog = SSHHostCatalog(paths: paths)
        let executable = Bundle.main.executableURL
        tunnelAuthorization = executable.map {
            SSHTunnelAskpassAuthorization(paths: paths, secretStore: secretStore, appExecutablePath: $0.path)
        }
        // Callbacks are set before the broker can serve any tunnel token.
        connectTunnelAuthorization()
        do {
            guard let executable else {
                throw SSHAskpassBroker.Error.listener
            }
            let broker = try SSHAskpassBroker(
                runtimeRoot: paths.runtimeRoot,
                appExecutablePath: executable.path,
                secretStore: secretStore,
                authority: authorization.authority,
                tunnelAuthority: tunnelAuthorization?.tunnelAuthority)
            askpassBroker = broker
            tunnelAuthorization?.attach(broker)
            broker.start()
        } catch {
            SSHLog.logger.error("SSH saved-password broker is unavailable; terminal authentication remains available.")
        }
        do {
            let metadata = try SSHHostMetadataStore(paths: paths).load().metadata
            catalog.setPresentationMetadata(
                displayNames: metadata.hosts.compactMapValues { $0.displayName },
                favorites: Set(metadata.favorites))
            tunnels.apply(metadata)
        } catch {
            SSHLog.logger.error("SSH host presentation metadata could not be loaded.")
        }
    }

    // MARK: - Tunnel prompts

    private func connectTunnelAuthorization() {
        guard let tunnelAuthorization else { return }
        tunnelAuthorization.present = { [weak self] request, reply in
            DispatchQueue.main.async {
                guard let self else { return reply(nil) }
                self.presentTunnelPrompt(request, reply: reply)
            }
        }
        tunnelAuthorization.dismiss = { [weak self] id in
            DispatchQueue.main.async { self?.tunnelPrompts.removeValue(forKey: id)?.cancel() }
        }
        tunnelAuthorization.authenticating = { [weak self] session, waiting in
            DispatchQueue.main.async {
                guard let manager = self?.tunnels.manager else { return }
                if waiting { manager.beginAuthentication(session: session) } else { manager.endAuthentication(session: session) }
            }
        }
        tunnelAuthorization.failed = { [weak self] session, message in
            DispatchQueue.main.async { self?.tunnels.manager.failAuthentication(session: session, message: message) }
        }
    }

    /// Host-key prompts are shown next to the destination resolved for the
    /// alias, so a question about another host stands out.
    private func presentTunnelPrompt(
        _ request: SSHTunnelPromptRequest,
        reply: @escaping @Sendable (SSHSecretBuffer?) -> Void
    ) {
        guard case .hostKey(let text) = request.prompt else {
            show(request, trust: nil, reply: reply)
            return
        }
        let snapshot = catalog.snapshot
        resolver.resolve(
            reference: request.host,
            paths: paths,
            observations: snapshot.observations,
            containsMatchExec: snapshot.containsMatchExec,
            reason: .connect
        ) { [weak self] result in
            DispatchQueue.main.async {
                let trust = SSHHostTrustSheetModel(
                    prompt: text,
                    alias: request.host.alias,
                    hostName: result?.destination.hostName,
                    port: result?.destination.port)
                guard let self else { return reply(nil) }
                self.show(request, trust: trust, reply: reply)
            }
        }
    }

    private func show(
        _ request: SSHTunnelPromptRequest,
        trust: SSHHostTrustSheetModel?,
        reply: @escaping @Sendable (SSHSecretBuffer?) -> Void
    ) {
        // A dismissal may have been handled before this prompt arrived.
        guard tunnelAuthorization?.isPending(request.id) == true else { return reply(nil) }
        let name = tunnels.definition(request.tunnelID)?.name ?? request.host.alias
        let sheet = SSHTunnelPromptSheet(request.prompt, tunnelName: name, trust: trust) { [weak self] answer in
            self?.tunnelPrompts[request.id] = nil
            reply(answer)
        }
        tunnelPrompts[request.id] = sheet
        // AppKit queues a sheet behind one already shown. Popovers are panels
        // that close on focus loss, so they never carry the prompt.
        let window = [NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0.map { $0.sheetParent ?? $0 } }
            .first { !($0 is NSPanel) }
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
        sheet.present(on: window)
    }

    deinit {
        askpassBroker?.stop()
    }

    func recordRecent(_ reference: SSHHostReference) {
        guard catalog.snapshot.entries.contains(where: { $0.reference == reference }) else {
            return
        }

        recentReferences.removeAll { $0 == reference }
        recentReferences.insert(reference, at: 0)
        recentReferences = Array(recentReferences.prefix(Self.recentHostLimit))
    }

    func removeUnavailableRecentReferences(using entries: [SSHHostEntry]) {
        let available = Set(entries.map(\.reference))
        recentReferences.removeAll { !available.contains($0) }
    }

    func setPasswordWarning(_ warning: String?, for hostID: UUID) {
        if let warning {
            passwordWarnings[hostID] = warning
        } else {
            passwordWarnings.removeValue(forKey: hostID)
        }
    }
}

@MainActor
final class SSHCapability {
    unowned let controller: TerminalController
    let services: SSHServices

    init(controller: TerminalController, services: SSHServices) {
        self.controller = controller
        self.services = services
    }

    func connect(_ reference: SSHHostReference, inSplit: Bool) {
        guard let entry = services.catalog.snapshot.entries.first(where: { $0.reference == reference }) else {
            return
        }
        services.connectService.connect(
            entry,
            placement: inSplit ? .split : .tab,
            capability: self)
    }

    func showHosts() {
        SSHHostsWindowController.shared.show(services: services)
    }

    func startTunnel(_ id: UUID) {
        services.tunnels.start(id)
    }

    func stopTunnel(_ id: UUID) {
        services.tunnels.stop(id)
    }
}
