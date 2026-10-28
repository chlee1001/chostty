import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

struct SSHHostDraft: Equatable {
    var alias = ""
    var hostName = ""
    var user = ""
    var port = ""
    var identityFiles: [String] = []
    var proxyJump = ""
    var identitiesOnly: Bool?
    var forwardAgent: Bool?
    var serverAliveInterval = ""
    var displayName = ""
    var auth: SSHManagedHostAuth = .sshConfig
    /// Keeps the jump host editor on Custom while its fields are still empty or
    /// happen to spell a host alias.
    var proxyJumpIsCustom = false

    init(
        alias: String = "",
        hostName: String = "",
        user: String = "",
        port: String = "",
        identityFiles: [String] = [],
        proxyJump: String = "",
        identitiesOnly: Bool? = nil,
        forwardAgent: Bool? = nil,
        serverAliveInterval: String = "",
        displayName: String = "",
        auth: SSHManagedHostAuth = .sshConfig
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
        self.identitiesOnly = identitiesOnly
        self.forwardAgent = forwardAgent
        self.serverAliveInterval = serverAliveInterval
        self.displayName = displayName
        self.auth = auth
    }

    init(host: SSHManagedHost, displayName: String?, auth: SSHManagedHostAuth = .sshConfig) {
        alias = host.alias
        hostName = host.hostName
        user = host.user ?? ""
        port = host.port.map(String.init) ?? ""
        identityFiles = host.identityFiles
        proxyJump = host.proxyJump ?? ""
        identitiesOnly = host.identitiesOnly
        forwardAgent = host.forwardAgent
        serverAliveInterval = host.serverAliveInterval.map(String.init) ?? ""
        self.displayName = displayName ?? ""
        self.auth = auth
    }
}

enum SSHPasswordStatus: Equatable, Sendable {
    case unavailableUntilHostSaved
    case noSavedPassword
    case ready
    case needsConfirmation(SSHTargetFingerprint)
    case locked
    case denied
    case unavailable
}

struct SSHTunnelDraft: Equatable {
    var id: UUID?
    var name = ""
    var host: SSHHostReference?
    var kind: SSHTunnelDefinition.Kind = .local
    var bindAddress = "127.0.0.1"
    var bindPort = ""
    var targetHost = "localhost"
    var targetPort = ""
    var consent: SSHBindConsent?

    init() {}

    init(_ definition: SSHTunnelDefinition) {
        id = definition.id
        name = definition.name
        host = definition.host
        kind = definition.kind
        bindAddress = definition.bindAddress
        bindPort = String(definition.bindPort)
        targetHost = definition.targetHost ?? "localhost"
        targetPort = definition.targetPort.map(String.init) ?? ""
        consent = definition.externalBindConsent
    }
}

struct SSHOutsideHost: Identifiable, Hashable {
    let alias: String
    let line: Int

    var id: String { "\(line):\(alias)" }
}

enum SSHJumpHostChoice: Hashable {
    case none
    case custom
    case host(String)
}

struct SSHJumpHostCheckState: Equatable {
    /// The ProxyJump value that was checked; a later edit hides the result.
    let proxyJump: String
    let result: SSHJumpHostCheckResult?
}

enum SSHHostsSelection: Hashable {
    case managed(UUID)
    case readOnly(SSHHostReference)
    case outside(SSHOutsideHost)
    case draft
    case tunnel(UUID)
    case tunnelDraft
}

@MainActor
final class SSHHostsEditorModel: ObservableObject {
    @Published private(set) var managedSnapshot = SSHManagedHostSnapshot(hosts: [], hash: nil)
    @Published private(set) var metadataSnapshot: SSHHostMetadataSnapshot?
    @Published private(set) var outsideHosts: [SSHOutsideHost] = []
    @Published var selection: SSHHostsSelection?
    @Published var draft: SSHHostDraft?
    @Published var tunnelDraft: SSHTunnelDraft?
    @Published private(set) var needsBindConsent = false
    @Published var query = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var resolvedDestination: SSHResolvedDestination?
    @Published private(set) var notCopied: [String] = []
    @Published private(set) var changedOnDisk = false
    @Published private(set) var partialSave = false
    @Published private(set) var needsMatchExecConsent = false
    @Published private(set) var passwordStatus: SSHPasswordStatus = .unavailableUntilHostSaved
    @Published private(set) var jumpHostCheck: SSHJumpHostCheckState?

    let paths: SSHPaths
    private let store: SSHManagedHostStore
    private let metadataStore: SSHHostMetadataStore
    let catalog: SSHHostCatalog
    private let resolver: any SSHResolving
    private let jumpHostChecker: any SSHJumpHostChecking
    private let secretStore: any SSHSecretStore
    private let connect: (SSHHostReference) -> Bool
    private let clearPasswordWarning: (UUID) -> Void
    let tunnels: SSHTunnelController?
    @Published private var passwordWarnings: [UUID: String] = [:]
    private var passwordWarningsCancellable: AnyCancellable?
    private var editedHostID: UUID?
    private var metadataIsDirty = false
    private var metadataLoadError: String?
    private var pendingMatchExecAction: MatchExecAction?
    private var passwordStatusRequestID = UUID()
    /// Identifies the jump host check whose result may be shown, so a slower
    /// earlier check of the same value cannot overwrite a newer one.
    private var jumpHostCheckRequestID = UUID()

    init(
        paths: SSHPaths,
        store: SSHManagedHostStore,
        metadata: SSHHostMetadataStore,
        catalog: SSHHostCatalog,
        resolver: any SSHResolving,
        jumpHostChecker: any SSHJumpHostChecking = SSHJumpHostChecker(),
        secretStore: any SSHSecretStore,
        tunnels: SSHTunnelController? = nil,
        passwordWarnings: AnyPublisher<[UUID: String], Never>,
        clearPasswordWarning: @escaping (UUID) -> Void,
        connect: @escaping (SSHHostReference) -> Bool
    ) {
        self.paths = paths
        self.tunnels = tunnels
        self.store = store
        metadataStore = metadata
        self.catalog = catalog
        self.resolver = resolver
        self.jumpHostChecker = jumpHostChecker
        self.secretStore = secretStore
        self.clearPasswordWarning = clearPasswordWarning
        self.connect = connect
        metadataSnapshot = nil
        passwordWarningsCancellable = passwordWarnings.sink { [weak self] warnings in
            self?.passwordWarnings = warnings
        }
        reload()
    }

    convenience init(
        paths: SSHPaths,
        catalog: SSHHostCatalog,
        resolver: any SSHResolving,
        jumpHostChecker: any SSHJumpHostChecking = SSHJumpHostChecker(),
        secretStore: any SSHSecretStore,
        tunnels: SSHTunnelController? = nil,
        passwordWarnings: AnyPublisher<[UUID: String], Never>,
        clearPasswordWarning: @escaping (UUID) -> Void,
        connect: @escaping (SSHHostReference) -> Bool
    ) {
        self.init(
            paths: paths,
            store: SSHManagedHostStore(paths: paths),
            metadata: SSHHostMetadataStore(paths: paths),
            catalog: catalog,
            resolver: resolver,
            jumpHostChecker: jumpHostChecker,
            secretStore: secretStore,
            tunnels: tunnels,
            passwordWarnings: passwordWarnings,
            clearPasswordWarning: clearPasswordWarning,
            connect: connect)
    }

    var managedHosts: [SSHManagedHost] { managedSnapshot.hosts }

    var readOnlyEntries: [SSHHostEntry] {
        catalog.snapshot.entries.filter {
            if case .managed = $0.reference.source { return false }
            return matches($0.reference.alias)
        }
    }

    var filteredManagedHosts: [SSHManagedHost] {
        managedHosts.filter { matches($0.alias) }
    }

    /// A fresh install has no hosts.conf yet; that is not a problem to report.
    var configDiagnostics: [SSHConfigDiagnostic] {
        catalog.snapshot.diagnostics.filter { $0 != .missing(paths.managedHostsFile) }
    }

    var filteredOutsideHosts: [SSHOutsideHost] {
        outsideHosts.filter { matches($0.alias) }
    }

    var selectedReadOnlyEntry: SSHHostEntry? {
        guard case .readOnly(let reference) = selection else { return nil }
        return catalog.snapshot.entries.first { $0.reference == reference }
    }

    var selectedOutsideHost: SSHOutsideHost? {
        guard case .outside(let host) = selection else { return nil }
        return host
    }

    var selectedManagedHost: SSHManagedHost? {
        guard let editedHostID else { return nil }
        return managedHosts.first { $0.hostID == editedHostID }
    }

    var selectedSourceURL: URL? {
        if let entry = selectedReadOnlyEntry { return entry.definedIn }
        if selectedOutsideHost != nil { return paths.managedHostsFile }
        return nil
    }

    var canSave: Bool { draft != nil && metadataSnapshot != nil }
    var canDelete: Bool { selectedManagedHost != nil && metadataSnapshot != nil }
    var canConnect: Bool { selectedReadOnlyEntry != nil || selectedManagedHost != nil }
    var savedToPath: String { savedToPath(for: paths.managedHostsFile) }
    var canManagePassword: Bool { currentPasswordMutationTarget(reportingError: false) != nil }
    var currentPasswordDestination: String {
        guard let (_, target) = currentPasswordMutationTarget(reportingError: false) else { return "this host" }
        return target.displayDestination
    }

    var keychainEligibilityDescription: String? {
        guard let draft, draft.auth == .keychain else { return nil }
        do {
            let host = try makeHost(from: draft)
            if let saved = selectedManagedHost,
               saved.alias.utf8.elementsEqual(draft.alias.utf8),
               !hasEndpointChanges(from: saved, draft: draft) {
                return keychainEligibilityMessage(for: try savedKeychainEligibility(for: saved))
            }
            return keychainEligibilityMessage(for: try keychainEligibility(for: host))
        } catch {
            return keychainEligibilityMessage(for: .ineligible(.invalidConfiguration))
        }
    }

    func reload() {
        var loadError: String?
        do {
            managedSnapshot = try store.load()
        } catch {
            loadError = error.localizedDescription
        }
        do {
            metadataSnapshot = try metadataStore.load()
            metadataIsDirty = false
            metadataLoadError = nil
        } catch {
            // A malformed metadata file must stay visible; never replace it with defaults.
            metadataSnapshot = nil
            metadataIsDirty = false
            metadataLoadError = error.localizedDescription
        }
        outsideHosts = unmanagedBlocks()
        catalog.refreshIfStale()
        publishPresentationMetadata()
        changedOnDisk = false
        partialSave = false
        resolvedDestination = nil
        jumpHostCheck = nil
        errorMessage = metadataLoadError ?? loadError
    }

    func reloadIfClean() {
        guard draft == nil, !metadataIsDirty else { return }
        reload()
    }

    func beginNewHost() {
        selection = .draft
        tunnelDraft = nil
        editedHostID = nil
        draft = SSHHostDraft()
        resolvedDestination = nil
        jumpHostCheck = nil
        notCopied = []
        errorMessage = metadataLoadError
        changedOnDisk = false
        passwordStatus = .unavailableUntilHostSaved
        passwordStatusRequestID = UUID()
    }

    func selectManaged(_ host: SSHManagedHost) {
        selection = .managed(host.hostID)
        tunnelDraft = nil
        editedHostID = host.hostID
        let metadata = metadataSnapshot?.metadata.hosts[host.hostID]
        draft = SSHHostDraft(host: host, displayName: metadata?.displayName, auth: metadata?.auth ?? .sshConfig)
        resolvedDestination = nil
        jumpHostCheck = nil
        notCopied = []
        errorMessage = metadataLoadError
        changedOnDisk = false
        refreshPasswordStatus(for: host)
    }

    func selectReadOnly(_ entry: SSHHostEntry) {
        selection = .readOnly(entry.reference)
        tunnelDraft = nil
        editedHostID = nil
        draft = nil
        resolvedDestination = entry.resolved
        jumpHostCheck = nil
        notCopied = []
        errorMessage = metadataLoadError
        changedOnDisk = false
        passwordStatus = .unavailableUntilHostSaved
        passwordStatusRequestID = UUID()
    }

    func selectOutside(_ host: SSHOutsideHost) {
        selection = .outside(host)
        tunnelDraft = nil
        editedHostID = nil
        draft = nil
        resolvedDestination = nil
        jumpHostCheck = nil
        notCopied = []
        errorMessage = metadataLoadError
        changedOnDisk = false
        passwordStatus = .unavailableUntilHostSaved
        passwordStatusRequestID = UUID()
    }

    func applySidebarSelection() {
        switch selection {
        case .managed(let hostID):
            guard editedHostID != hostID, let host = managedHosts.first(where: { $0.hostID == hostID }) else { return }
            selectManaged(host)
        case .readOnly(let reference):
            guard let entry = catalog.snapshot.entries.first(where: { $0.reference == reference }) else { return }
            selectReadOnly(entry)
        case .outside(let host):
            selectOutside(host)
        case .tunnel(let id):
            guard tunnelDraft?.id != id, let definition = tunnelDefinitions.first(where: { $0.id == id }) else { return }
            selectTunnel(definition)
        case .draft, .tunnelDraft, .none:
            break
        }
    }

    func draftBinding<Value>(_ keyPath: WritableKeyPath<SSHHostDraft, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { self.draft?[keyPath: keyPath] ?? defaultValue },
            set: { value in
                guard var draft = self.draft else { return }
                draft[keyPath: keyPath] = value
                self.draft = draft
            })
    }

    func addIdentityFile() {
        guard var draft else { return }
        draft.identityFiles.append("")
        self.draft = draft
    }

    func removeIdentityFile(at index: Int) {
        guard var draft, draft.identityFiles.indices.contains(index) else { return }
        draft.identityFiles.remove(at: index)
        self.draft = draft
    }

    /// Sets an IdentityFile row to a chosen file, written with `~` when it is
    /// under the home folder and with `%` escaped, since ssh expands tokens.
    /// ssh config needs quotes for spaces, which the managed hosts file does
    /// not write, so such a path is refused, as is a public key.
    func setIdentityFile(_ url: URL, at index: Int, home: String = NSHomeDirectory()) {
        let path = Self.identityFilePath(url.path, home: home)
        guard path.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            errorMessage = "An IdentityFile path cannot contain spaces. Choose a key at a path without spaces."
            return
        }
        guard url.pathExtension != "pub" else {
            errorMessage = "Choose the private key, not the .pub file."
            return
        }
        identityFileBinding(at: index).wrappedValue = path.replacingOccurrences(of: "%", with: "%%")
        errorMessage = metadataLoadError
    }

    static func identityFilePath(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    var jumpHostChoices: [String] {
        let excluded = [draft?.alias, selectedManagedHost?.alias].compactMap { $0 }
        var seen = Set<String>()
        return catalog.snapshot.entries.map(\.reference.alias).filter {
            !excluded.contains($0) && seen.insert($0).inserted
        }
    }

    var jumpHostChoice: SSHJumpHostChoice {
        guard let draft, !draft.proxyJump.isEmpty || draft.proxyJumpIsCustom else { return .none }
        if !draft.proxyJumpIsCustom, jumpHostChoices.contains(draft.proxyJump) { return .host(draft.proxyJump) }
        return .custom
    }

    var jumpHostChoiceBinding: Binding<SSHJumpHostChoice> {
        Binding(
            get: { self.jumpHostChoice },
            set: { choice in
                guard var draft = self.draft else { return }
                switch choice {
                case .none:
                    draft.proxyJump = ""
                    draft.proxyJumpIsCustom = false
                case .custom:
                    draft.proxyJumpIsCustom = true
                case .host(let alias):
                    draft.proxyJump = alias
                    draft.proxyJumpIsCustom = false
                }
                self.draft = draft
            })
    }

    func jumpHopBinding(_ keyPath: WritableKeyPath<SSHProxyJumpHop, String>) -> Binding<String> {
        Binding(
            get: { SSHProxyJumpHop(parsing: self.draft?.proxyJump ?? "")[keyPath: keyPath] },
            set: { value in
                guard var draft = self.draft else { return }
                var hop = SSHProxyJumpHop(parsing: draft.proxyJump)
                Self.setHopField(keyPath, to: value, in: &hop)
                draft.proxyJump = hop.value
                draft.proxyJumpIsCustom = true
                self.draft = draft
            })
    }

    static func setHopField(_ keyPath: WritableKeyPath<SSHProxyJumpHop, String>, to value: String, in hop: inout SSHProxyJumpHop) {
        let pasted = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyPath == \SSHProxyJumpHop.host,
           pasted.contains("@") || pasted.hasPrefix("[") || pasted.hasPrefix("ssh://"),
           SSHProxyJumpHop.isValid(pasted) {
            let parsed = SSHProxyJumpHop(parsing: pasted)
            hop.host = parsed.host
            if !parsed.user.isEmpty { hop.user = parsed.user }
            if !parsed.port.isEmpty { hop.port = parsed.port }
            return
        }
        let reserved = CharacterSet(charactersIn: "@,[]/").union(.whitespacesAndNewlines)
        var value = String(value.unicodeScalars.filter { !reserved.contains($0) })
        if keyPath == \SSHProxyJumpHop.host, let colon = value.firstIndex(of: ":"), value.lastIndex(of: ":") == colon {
            let port = String(value[value.index(after: colon)...])
            if !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) {
                value = String(value[..<colon])
                hop.port = port
            }
        } else if keyPath != \SSHProxyJumpHop.host {
            value.removeAll { $0 == ":" }
        }
        hop[keyPath: keyPath] = value
    }

    var canCheckJumpHost: Bool {
        guard let value = draft?.proxyJump else { return false }
        return SSHProxyJump.isSingleHop(value) && jumpHostCheck.map { $0.result != nil || $0.proxyJump != value } ?? true
    }

    var currentJumpHostCheck: SSHJumpHostCheckState? {
        guard let jumpHostCheck, jumpHostCheck.proxyJump == draft?.proxyJump else { return nil }
        return jumpHostCheck
    }

    func checkJumpHost(allowMatchExec: Bool = false) {
        guard let value = draft?.proxyJump, SSHProxyJump.isSingleHop(value) else { return }
        let containsMatchExec = catalog.snapshot.containsMatchExec
        guard !containsMatchExec || allowMatchExec else {
            pendingMatchExecAction = .checkJumpHost
            needsMatchExecConsent = true
            return
        }
        needsMatchExecConsent = false
        let managedFile = paths.managedHostsFile
        let configFile = FileManager.default.fileExists(atPath: managedFile.path) ? managedFile : nil
        jumpHostCheck = SSHJumpHostCheckState(proxyJump: value, result: nil)
        let requestID = UUID()
        jumpHostCheckRequestID = requestID
        jumpHostChecker.check(
            proxyJump: value,
            configFile: configFile,
            containsMatchExec: containsMatchExec,
            allowMatchExec: allowMatchExec
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.jumpHostCheckRequestID == requestID,
                      self.jumpHostCheck == SSHJumpHostCheckState(proxyJump: value, result: nil) else { return }
                self.jumpHostCheck = SSHJumpHostCheckState(proxyJump: value, result: result)
            }
        }
    }

    func identityFileBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { self.draft?.identityFiles.indices.contains(index) == true ? self.draft!.identityFiles[index] : "" },
            set: { value in
                guard var draft = self.draft, draft.identityFiles.indices.contains(index) else { return }
                draft.identityFiles[index] = value
                self.draft = draft
            })
    }

    func optionalBooleanBinding(_ keyPath: WritableKeyPath<SSHHostDraft, Bool?>) -> Binding<Int> {
        Binding(
            get: {
                switch self.draft?[keyPath: keyPath] {
                case true: 1
                case false: 2
                case nil: 0
                }
            },
            set: { value in
                guard var draft = self.draft else { return }
                switch value {
                case 1:
                    draft[keyPath: keyPath] = true
                case 2:
                    draft[keyPath: keyPath] = false
                default:
                    draft[keyPath: keyPath] = nil
                }
                self.draft = draft
            })
    }

    func setFavorite(_ favorite: Bool, for reference: SSHHostReference) {
        guard let snapshot = requireMetadataSnapshot() else { return }
        var favorites = Set(snapshot.metadata.favorites)
        if favorite {
            favorites.insert(reference)
        } else {
            favorites.remove(reference)
        }
        do {
            metadataSnapshot = SSHHostMetadataSnapshot(
                metadata: try SSHHostMetadataFile(
                    hosts: snapshot.metadata.hosts,
                    favorites: Array(favorites),
                    tunnels: snapshot.metadata.tunnels),
                hash: snapshot.hash)
            metadataIsDirty = true
            publishPresentationMetadata()
            savePresentationMetadata()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isFavorite(_ reference: SSHHostReference) -> Bool {
        metadataSnapshot?.metadata.favorites.contains(reference) ?? false
    }

    func save(overwritingExternalChanges: Bool = false) {
        guard requireMetadataSnapshot() != nil else { return }
        guard let draft else {
            errorMessage = "Select a Chostty host or create a new host before saving."
            return
        }
        let host: SSHManagedHost
        do {
            host = try makeHost(from: draft)
            try catalog.validateUniqueAlias(host.alias, excluding: editedHostID)
            if draft.auth == .keychain {
                let eligibility = try keychainEligibility(for: host)
                guard case .eligible = eligibility else {
                    errorMessage = keychainEligibilityMessage(for: eligibility)
                    return
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        do {
            let expectedHash = try expectedHostsHash(overwritingExternalChanges)
            let saved = try store.save(host, expectedHash: expectedHash)
            managedSnapshot = saved
            editedHostID = host.hostID
            selection = .managed(host.hostID)
            // The saved file may change how the jump host resolves.
            jumpHostCheck = nil
            self.draft = SSHHostDraft(
                host: host,
                displayName: normalizedOptional(draft.displayName),
                auth: draft.auth)

            do {
                try saveMetadata(for: host, draft: draft, overwritingExternalChanges: overwritingExternalChanges)
            } catch {
                // The host is already durable. Keep the metadata edits in memory and report that state exactly.
                managedSnapshot = (try? store.load()) ?? saved
                metadataIsDirty = true
                partialSave = true
                changedOnDisk = isChangedOnDisk(error)
                errorMessage = "Host saved, but its presentation metadata was not saved: \(error.localizedDescription)"
                catalog.refreshIfStale()
                publishPresentationMetadata()
                return
            }

            metadataIsDirty = false
            partialSave = false
            changedOnDisk = false
            errorMessage = metadataLoadError
            catalog.refreshIfStale()
            publishPresentationMetadata()
            refreshPasswordStatus(for: host)
        } catch {
            changedOnDisk = isChangedOnDisk(error)
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected(overwritingExternalChanges: Bool = false) {
        guard let metadataSnapshot = requireMetadataSnapshot() else { return }
        guard let host = selectedManagedHost else {
            errorMessage = "Only Chostty-managed hosts can be deleted."
            return
        }
        let running = tunnels?.runningTunnels(forManagedHost: host.hostID) ?? []
        if !running.isEmpty, tunnels?.stopNow(running.map(\.id)) == false {
            errorMessage = "The host's tunnels could not be stopped, so the host was not deleted."
            return
        }
        var deleted = false
        do {
            let expectedHash = try expectedHostsHash(overwritingExternalChanges)
            let saved = try store.delete(hostID: host.hostID, expectedHash: expectedHash)
            deleted = true
            managedSnapshot = saved
            selection = nil
            editedHostID = nil
            draft = nil

            var hosts = metadataSnapshot.metadata.hosts
            hosts.removeValue(forKey: host.hostID)
            let favorites = metadataSnapshot.metadata.favorites.filter { reference in
                reference != SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias)
            }
            // A deleted managed host takes its tunnels with it; their host
            // reference can never resolve again.
            let tunnels = metadataSnapshot.metadata.tunnels.filter { tunnel in
                tunnel.host.source != .managed(hostID: host.hostID)
            }
            let metadata = try SSHHostMetadataFile(hosts: hosts, favorites: favorites, tunnels: tunnels)
            let metadataHash = try expectedMetadataHash(overwritingExternalChanges)
            self.metadataSnapshot = try metadataStore.save(metadata, expectedHash: metadataHash)
            metadataIsDirty = false
            partialSave = false
            changedOnDisk = false
            do {
                try secretStore.deletePassword(for: host.hostID)
            } catch SSHSecretStoreError.notFound {
                // Deletion is idempotent: a mode switch can leave no saved item.
            } catch {
                partialSave = true
                errorMessage = "Host deleted, but its saved password could not be removed: \(passwordStoreMessage(for: error))"
                return
            }
            clearPasswordWarning(host.hostID)
            passwordStatus = .unavailableUntilHostSaved
            errorMessage = metadataLoadError
            catalog.refreshIfStale()
            publishPresentationMetadata()
        } catch {
            if deleted {
                managedSnapshot = (try? store.load()) ?? managedSnapshot
                metadataIsDirty = true
                partialSave = true
                catalog.refreshIfStale()
                publishPresentationMetadata()
                let metadataError = error
                do {
                    try secretStore.deletePassword(for: host.hostID)
                    clearPasswordWarning(host.hostID)
                    passwordStatus = .unavailableUntilHostSaved
                    errorMessage = "Host deleted, but its presentation metadata was not saved: \(metadataError.localizedDescription)"
                } catch SSHSecretStoreError.notFound {
                    clearPasswordWarning(host.hostID)
                    passwordStatus = .unavailableUntilHostSaved
                    errorMessage = "Host deleted, but its presentation metadata was not saved: \(metadataError.localizedDescription)"
                } catch {
                    errorMessage = "Host deleted, but its presentation metadata and saved password could not be removed."
                }
                changedOnDisk = isChangedOnDisk(error)
                return
            }
            changedOnDisk = isChangedOnDisk(error)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Tunnels

    var tunnelDefinitions: [SSHTunnelDefinition] {
        (metadataSnapshot?.metadata.tunnels ?? []).filter { matches($0.name) }
    }

    var tunnelHosts: [SSHHostEntry] { catalog.snapshot.entries }

    var selectedHostRunningTunnelCount: Int {
        guard let host = selectedManagedHost else { return 0 }
        return tunnels?.runningTunnels(forManagedHost: host.hostID).count ?? 0
    }

    var selectedTunnelIsRunning: Bool {
        guard let id = tunnelDraft?.id else { return false }
        return tunnels?.isRunning(id) == true
    }

    var canSaveTunnel: Bool { tunnelDraft != nil && metadataSnapshot != nil && !selectedTunnelIsRunning }
    var canDeleteTunnel: Bool { tunnelDraft?.id != nil && metadataSnapshot != nil && !selectedTunnelIsRunning }

    func beginNewTunnel() {
        selection = .tunnelDraft
        editedHostID = nil
        draft = nil
        var tunnel = SSHTunnelDraft()
        tunnel.host = tunnelHosts.first?.reference
        tunnelDraft = tunnel
        resolvedDestination = nil
        jumpHostCheck = nil
        notCopied = []
        errorMessage = metadataLoadError
        changedOnDisk = false
    }

    func selectTunnel(_ definition: SSHTunnelDefinition) {
        selection = .tunnel(definition.id)
        editedHostID = nil
        draft = nil
        tunnelDraft = SSHTunnelDraft(definition)
        resolvedDestination = nil
        jumpHostCheck = nil
        notCopied = []
        errorMessage = metadataLoadError
        changedOnDisk = false
    }

    func tunnelDraftBinding<Value>(_ keyPath: WritableKeyPath<SSHTunnelDraft, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { self.tunnelDraft?[keyPath: keyPath] ?? defaultValue },
            set: { value in
                guard var draft = self.tunnelDraft else { return }
                draft[keyPath: keyPath] = value
                self.tunnelDraft = draft
            })
    }

    /// Saves the edited tunnel. A bind beyond loopback needs explicit consent
    /// first; without it nothing is saved or started.
    func saveTunnel(grantingBindConsent: Bool = false, overwritingExternalChanges: Bool = false) {
        guard let snapshot = requireMetadataSnapshot(), let draft = tunnelDraft else { return }
        guard !selectedTunnelIsRunning else {
            errorMessage = "Stop the tunnel before editing it."
            return
        }
        guard let host = draft.host else {
            errorMessage = "Choose a host for this tunnel."
            return
        }
        do {
            let usesTarget = draft.kind != .dynamic
            var definition = SSHTunnelDefinition(
                id: draft.id ?? UUID(),
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host,
                kind: draft.kind,
                bindAddress: draft.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                bindPort: try requiredInteger(draft.bindPort, label: "Bind port"),
                targetHost: usesTarget ? draft.targetHost.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                targetPort: usesTarget ? try requiredInteger(draft.targetPort, label: "Target port") : nil)
            if SSHBindConsent.requiresConsent(for: definition.bindAddress) {
                if let consent = draft.consent,
                   consent.matches(address: definition.bindAddress, port: definition.bindPort, kind: definition.kind) {
                    definition.externalBindConsent = consent
                } else if grantingBindConsent {
                    definition.externalBindConsent = SSHBindConsent(
                        address: definition.bindAddress,
                        port: definition.bindPort,
                        kind: definition.kind,
                        grantedAt: Date())
                } else {
                    needsBindConsent = true
                    return
                }
            }
            try definition.validate()

            var definitions = snapshot.metadata.tunnels
            if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
                definitions[index] = definition
            } else {
                definitions.append(definition)
            }
            let metadata = try SSHHostMetadataFile(
                hosts: snapshot.metadata.hosts,
                favorites: snapshot.metadata.favorites,
                tunnels: definitions)
            metadataSnapshot = try metadataStore.save(
                metadata,
                expectedHash: try expectedMetadataHash(overwritingExternalChanges))
            metadataIsDirty = false
            tunnelDraft = SSHTunnelDraft(definition)
            selection = .tunnel(definition.id)
            changedOnDisk = false
            errorMessage = metadataLoadError
            publishPresentationMetadata()
        } catch {
            changedOnDisk = isChangedOnDisk(error)
            errorMessage = error.localizedDescription
        }
    }

    func dismissBindConsent() {
        needsBindConsent = false
    }

    func confirmBindConsent() {
        needsBindConsent = false
        saveTunnel(grantingBindConsent: true)
    }

    func deleteSelectedTunnel(overwritingExternalChanges: Bool = false) {
        guard let snapshot = requireMetadataSnapshot(), let id = tunnelDraft?.id else { return }
        guard !selectedTunnelIsRunning else {
            errorMessage = "Stop the tunnel before deleting it."
            return
        }
        do {
            let metadata = try SSHHostMetadataFile(
                hosts: snapshot.metadata.hosts,
                favorites: snapshot.metadata.favorites,
                tunnels: snapshot.metadata.tunnels.filter { $0.id != id })
            metadataSnapshot = try metadataStore.save(
                metadata,
                expectedHash: try expectedMetadataHash(overwritingExternalChanges))
            metadataIsDirty = false
            tunnelDraft = nil
            selection = nil
            changedOnDisk = false
            errorMessage = metadataLoadError
            publishPresentationMetadata()
        } catch {
            changedOnDisk = isChangedOnDisk(error)
            errorMessage = error.localizedDescription
        }
    }

    func connectSelected() {
        let reference: SSHHostReference?
        if let host = selectedManagedHost {
            reference = SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias)
        } else {
            reference = selectedReadOnlyEntry?.reference
        }
        guard let reference else {
            errorMessage = "Select a host to connect."
            return
        }
        guard connect(reference) else {
            errorMessage = "Open a terminal workspace before connecting."
            return
        }
        errorMessage = metadataLoadError
    }

    func resolveSelected(allowMatchExec: Bool = false) {
        guard let reference = selectedReadOnlyEntry?.reference ?? selectedManagedHost.map({
            SSHHostReference(source: .managed(hostID: $0.hostID), alias: $0.alias)
        }) else {
            errorMessage = "Select a host to resolve."
            return
        }
        guard !catalog.snapshot.containsMatchExec || allowMatchExec else {
            pendingMatchExecAction = .resolve
            needsMatchExecConsent = true
            return
        }
        needsMatchExecConsent = false
        resolver.resolve(
            reference: reference,
            paths: paths,
            observations: catalog.snapshot.observations,
            containsMatchExec: catalog.snapshot.containsMatchExec,
            reason: .explicit(allowMatchExec: allowMatchExec)
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let result else {
                    self.errorMessage = "ssh -G could not resolve this host."
                    return
                }
                self.resolvedDestination = result.destination
                self.catalog.updateResolvedDestination(result.destination, for: reference)
                self.errorMessage = self.metadataLoadError
            }
        }
    }

    func duplicateSelected(alias: String, allowMatchExec: Bool = false) {
        guard let reference = selectedReadOnlyEntry?.reference else {
            errorMessage = "Only a read-only SSH config host can be duplicated to edit."
            return
        }
        do {
            try catalog.validateUniqueAlias(alias, excluding: nil)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !catalog.snapshot.containsMatchExec || allowMatchExec else {
            pendingMatchExecAction = .duplicate(alias)
            needsMatchExecConsent = true
            return
        }
        needsMatchExecConsent = false
        SSHDuplicateToEdit(resolver: resolver).duplicate(
            reference: reference,
            paths: paths,
            observations: catalog.snapshot.observations,
            containsMatchExec: catalog.snapshot.containsMatchExec,
            allowMatchExec: allowMatchExec,
            alias: alias
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let result):
                    self.selection = .draft
                    self.editedHostID = nil
                    self.draft = SSHHostDraft(host: result.host, displayName: nil)
                    self.jumpHostCheck = nil
                    self.notCopied = result.notCopied
                    self.errorMessage = self.metadataLoadError
                case .failure(let error):
                    self.errorMessage = self.message(for: error)
                }
            }
        }
    }

    func openSelectedInExternalEditor() {
        guard let source = selectedSourceURL else { return }
        NSWorkspace.shared.open(source)
    }

    func dismissMatchExecConsent() {
        pendingMatchExecAction = nil
        needsMatchExecConsent = false
    }

    func confirmMatchExecConsent() {
        guard let action = pendingMatchExecAction else { return }
        pendingMatchExecAction = nil
        needsMatchExecConsent = false
        switch action {
        case .resolve:
            resolveSelected(allowMatchExec: true)
        case .duplicate(let alias):
            duplicateSelected(alias: alias, allowMatchExec: true)
        case .checkJumpHost:
            checkJumpHost(allowMatchExec: true)
        }
    }

    func savePresentationMetadata(overwritingExternalChanges: Bool = false) {
        guard metadataIsDirty else { return }
        guard let snapshot = requireMetadataSnapshot() else { return }
        do {
            let expectedHash = try expectedMetadataHash(overwritingExternalChanges)
            metadataSnapshot = try metadataStore.save(snapshot.metadata, expectedHash: expectedHash)
            metadataIsDirty = false
            changedOnDisk = false
            errorMessage = metadataLoadError
            publishPresentationMetadata()
        } catch {
            changedOnDisk = isChangedOnDisk(error)
            errorMessage = error.localizedDescription
        }
    }

    func savePassword(_ secret: SSHSecretBuffer) {
        defer { secret.wipe() }
        guard let (host, target) = currentPasswordMutationTarget() else { return }
        do {
            try secretStore.setPassword(secret, for: host.hostID, target: target, label: host.alias)
            passwordStatusRequestID = UUID()
            clearPasswordWarning(host.hostID)
            passwordStatus = .ready
            errorMessage = metadataLoadError
        } catch {
            errorMessage = passwordStoreMessage(for: error)
        }
    }

    func confirmPasswordTarget() {
        guard let (host, target) = currentPasswordMutationTarget() else { return }
        do {
            try secretStore.updateTarget(target, for: host.hostID)
            passwordStatusRequestID = UUID()
            clearPasswordWarning(host.hostID)
            passwordStatus = .ready
            errorMessage = metadataLoadError
        } catch {
            errorMessage = passwordStoreMessage(for: error)
        }
    }

    func removePassword() {
        guard let (host, _) = currentPasswordMutationTarget() else { return }
        do {
            try secretStore.deletePassword(for: host.hostID)
            passwordStatusRequestID = UUID()
            clearPasswordWarning(host.hostID)
            passwordStatus = .noSavedPassword
            errorMessage = metadataLoadError
        } catch SSHSecretStoreError.notFound {
            passwordStatusRequestID = UUID()
            clearPasswordWarning(host.hostID)
            passwordStatus = .noSavedPassword
            errorMessage = metadataLoadError
        } catch {
            errorMessage = passwordStoreMessage(for: error)
        }
    }

    var passwordWarning: String? {
        guard let hostID = selectedManagedHost?.hostID else { return nil }
        return passwordWarnings[hostID]
    }

    private func currentPasswordMutationTarget(reportingError: Bool = true) -> (SSHManagedHost, SSHTargetFingerprint)? {
        guard let host = selectedManagedHost, let draft else {
            if reportingError { errorMessage = "Save this host before managing a password." }
            return nil
        }
        guard draft.auth == .keychain else {
            if reportingError { errorMessage = "Select Password in Keychain and save the host changes first." }
            return nil
        }
        guard metadataSnapshot?.metadata.hosts[host.hostID]?.auth == .keychain else {
            if reportingError { errorMessage = "Save host changes before managing a password." }
            return nil
        }
        do {
            let metadataOnDisk = try metadataStore.load()
            let hostsOnDisk = try store.load()
            guard let currentMetadata = metadataSnapshot,
                  metadataOnDisk.hash == currentMetadata.hash,
                  hostsOnDisk.hash == managedSnapshot.hash,
                  hostsOnDisk.hosts.contains(where: { $0 == host })
            else {
                if reportingError {
                    changedOnDisk = true
                    errorMessage = "Host changed on disk. Reload before managing a password."
                }
                return nil
            }
        } catch {
            if reportingError { errorMessage = error.localizedDescription }
            return nil
        }
        guard !hasEndpointChanges(from: host, draft: draft) else {
            if reportingError { errorMessage = "Save host changes before managing a password." }
            return nil
        }
        do {
            let eligibility = try savedKeychainEligibility(for: host)
            guard case .eligible(let target) = eligibility else {
                if reportingError { errorMessage = keychainEligibilityMessage(for: eligibility) }
                return nil
            }
            return (host, target)
        } catch {
            if reportingError { errorMessage = error.localizedDescription }
            return nil
        }
    }

    private func refreshPasswordStatus(for host: SSHManagedHost) {
        guard metadataSnapshot?.metadata.hosts[host.hostID]?.auth == .keychain else {
            passwordStatus = .noSavedPassword
            return
        }
        let target: SSHTargetFingerprint
        do {
            let eligibility = try savedKeychainEligibility(for: host)
            guard case .eligible(let eligibleTarget) = eligibility else {
                passwordStatus = .unavailable
                errorMessage = keychainEligibilityMessage(for: eligibility)
                return
            }
            target = eligibleTarget
        } catch {
            passwordStatus = .unavailable
            errorMessage = error.localizedDescription
            return
        }
        let store = secretStore
        let hostID = host.hostID
        let requestID = UUID()
        passwordStatusRequestID = requestID
        Task.detached {
            let status: SSHPasswordStatus
            do {
                let stored = try store.target(for: hostID)
                status = stored == target ? .ready : .needsConfirmation(stored)
            } catch SSHSecretStoreError.notFound {
                status = .noSavedPassword
            } catch SSHSecretStoreError.locked {
                status = .locked
            } catch SSHSecretStoreError.denied {
                status = .denied
            } catch {
                status = .unavailable
            }
            await MainActor.run {
                guard self.selectedManagedHost?.hostID == hostID,
                      self.draft?.auth == .keychain,
                      self.passwordStatusRequestID == requestID,
                      !self.hasEndpointChanges(from: host, draft: self.draft ?? SSHHostDraft())
                else { return }
                self.passwordStatus = status
            }
        }
    }

    private func keychainEligibility(for host: SSHManagedHost) throws -> SSHKeychainEligibility {
        let contents: Data
        if FileManager.default.fileExists(atPath: paths.managedHostsFile.path) {
            contents = try Data(contentsOf: paths.managedHostsFile)
        } else {
            contents = Data()
        }
        var document = SSHConfigDocument(data: contents)
        try document.upsertManagedHost(host)
        return SSHKeychainEligibility.evaluate(document: document, hostID: host.hostID)
    }

    private func savedKeychainEligibility(for host: SSHManagedHost) throws -> SSHKeychainEligibility {
        let contents = try SSHSecureFileWriter().read(at: paths.managedHostsFile)
        guard contents.hash == managedSnapshot.hash else { throw SSHStoreError.changedOnDisk }
        return SSHKeychainEligibility.evaluate(
            document: SSHConfigDocument(data: contents.data ?? Data()), hostID: host.hostID)
    }

    private func hasEndpointChanges(from host: SSHManagedHost, draft: SSHHostDraft) -> Bool {
        let sameUser = switch (host.user, normalizedOptional(draft.user)) {
        case (nil, nil): true
        case (let saved?, let edited?): saved.utf8.elementsEqual(edited.utf8)
        default: false
        }
        return !sameUser ||
            !host.hostName.utf8.elementsEqual(draft.hostName.utf8) ||
            host.port != (try? optionalInteger(draft.port, label: "Port"))
    }

    private func keychainEligibilityMessage(for eligibility: SSHKeychainEligibility) -> String {
        switch eligibility {
        case .eligible(let target):
            return "Eligible for \(target.displayDestination)."
        case .ineligible(.missingUser):
            return "Password in Keychain requires an explicit User."
        case .ineligible(.missingHostName):
            return "Password in Keychain requires an explicit HostName."
        case .ineligible(.missingPort):
            return "Password in Keychain requires an explicit Port."
        case .ineligible(.precededByHost(let line)):
            return "Password in Keychain is unsafe because a matching Host block appears first at line \(line)."
        case .ineligible(.precededByMatch(let line)):
            return "Password in Keychain is unsafe because Match appears first at line \(line)."
        case .ineligible(.scopeOverride(let line)):
            return "Password in Keychain is unsafe because an earlier option applies at line \(line)."
        case .ineligible(.includedScope(let line)):
            return "Password in Keychain is unsafe because Include affects this host at line \(line)."
        case .ineligible(.invalidConfiguration), .ineligible(.blockNotFound):
            return "Password in Keychain requires a saved, valid Chostty host."
        }
    }

    private func passwordStoreMessage(for error: Error) -> String {
        switch error {
        case SSHSecretStoreError.notFound:
            return "No saved password."
        case SSHSecretStoreError.locked:
            return "Saved password is locked."
        case SSHSecretStoreError.denied:
            return "Saved password access was denied."
        case SSHSecretStoreError.targetMismatch:
            return "Saved password needs confirmation."
        default:
            return "Saved password could not be changed."
        }
    }

    private func saveMetadata(for host: SSHManagedHost, draft: SSHHostDraft, overwritingExternalChanges: Bool) throws {
        guard let snapshot = metadataSnapshot else {
            throw SSHHostsEditorError.metadataUnavailable
        }
        var hosts = snapshot.metadata.hosts
        let displayName = normalizedOptional(draft.displayName)
        if displayName == nil {
            if draft.auth == .sshConfig {
                hosts.removeValue(forKey: host.hostID)
            } else {
                hosts[host.hostID] = try SSHManagedHostMetadata(auth: draft.auth)
            }
        } else {
            hosts[host.hostID] = try SSHManagedHostMetadata(displayName: displayName, auth: draft.auth)
        }
        let metadata = try SSHHostMetadataFile(
            hosts: hosts,
            favorites: snapshot.metadata.favorites,
            tunnels: snapshot.metadata.tunnels)
        guard metadataIsDirty || metadata != snapshot.metadata else { return }
        let expectedHash = try expectedMetadataHash(overwritingExternalChanges)
        metadataSnapshot = try metadataStore.save(metadata, expectedHash: expectedHash)
    }

    private func expectedHostsHash(_ overwriting: Bool) throws -> Data? {
        overwriting ? try store.load().hash : managedSnapshot.hash
    }

    private func expectedMetadataHash(_ overwriting: Bool) throws -> Data? {
        if overwriting {
            return try metadataStore.load().hash
        }
        guard let metadataSnapshot else {
            throw SSHHostsEditorError.metadataUnavailable
        }
        return metadataSnapshot.hash
    }

    private func makeHost(from draft: SSHHostDraft) throws -> SSHManagedHost {
        let port = try optionalInteger(draft.port, label: "Port")
        let interval = try optionalInteger(draft.serverAliveInterval, label: "ServerAliveInterval")
        let identities = draft.identityFiles.filter { !$0.isEmpty }
        let proxyJump = normalizedOptional(draft.proxyJump)
        if let proxyJump, !SSHProxyJump.isValid(proxyJump) {
            throw SSHHostsEditorError.invalidProxyJump
        }
        return try SSHManagedHost(
            hostID: editedHostID ?? UUID(),
            alias: draft.alias,
            hostName: draft.hostName,
            user: normalizedOptional(draft.user),
            port: port,
            identityFiles: identities,
            proxyJump: proxyJump,
            identitiesOnly: draft.identitiesOnly,
            forwardAgent: draft.forwardAgent,
            serverAliveInterval: interval,
            otherLines: selectedManagedHost?.otherLines ?? [])
    }

    private func optionalInteger(_ value: String, label: String) throws -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Int(value) else {
            throw SSHHostsEditorError.invalidInteger(label)
        }
        return number
    }

    private func requiredInteger(_ value: String, label: String) throws -> Int {
        guard let number = try optionalInteger(value, label: label) else {
            throw SSHHostsEditorError.invalidInteger(label)
        }
        return number
    }

    private func normalizedOptional(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func publishPresentationMetadata() {
        guard let metadataSnapshot else {
            catalog.setPresentationMetadata(displayNames: [:], favorites: [])
            return
        }
        let displayNames = Dictionary(uniqueKeysWithValues: metadataSnapshot.metadata.hosts.compactMap { id, metadata in
            metadata.displayName.map { (id, $0) }
        })
        catalog.setPresentationMetadata(
            displayNames: displayNames,
            favorites: Set(metadataSnapshot.metadata.favorites))
        tunnels?.apply(metadataSnapshot.metadata)
    }

    private func unmanagedBlocks() -> [SSHOutsideHost] {
        guard let text = try? String(contentsOf: paths.managedHostsFile, encoding: .utf8) else { return [] }
        let document = SSHConfigDocument(text: text)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var result: [SSHOutsideHost] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, String(parts[0]).caseInsensitiveCompare("Host") == .orderedSame else { continue }
            let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
            guard !previous.hasPrefix("# chostty-host-id:") else { continue }
            for alias in parts.dropFirst() where !alias.contains("*") && !alias.contains("!") {
                let alias = String(alias)
                let isManaged = document.blocks(matching: alias).contains {
                    $0.line == index + 1 && $0.managedHostID != nil
                }
                if !isManaged {
                    result.append(SSHOutsideHost(alias: alias, line: index + 1))
                }
            }
        }
        return result
    }

    private func matches(_ value: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || value.localizedCaseInsensitiveContains(needle)
    }

    func savedToPath(for url: URL) -> String {
        let home = paths.home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func isChangedOnDisk(_ error: Error) -> Bool {
        guard let storeError = error as? SSHStoreError else { return false }
        return storeError == .changedOnDisk
    }

    private func requireMetadataSnapshot() -> SSHHostMetadataSnapshot? {
        guard let metadataSnapshot else {
            errorMessage = metadataLoadError ?? "SSH host metadata could not be loaded."
            return nil
        }
        return metadataSnapshot
    }

    private func message(for error: SSHDuplicateToEditError) -> String {
        switch error {
        case .matchExecConsentRequired:
            "Resolving this host requires approval to run Match exec."
        case .invalidAlias:
            "The new SSH host alias is invalid."
        case .aliasMustDiffer:
            "The duplicated host needs a different alias."
        case .resolutionFailed:
            "ssh -G could not resolve this host."
        case .invalidResolvedValue:
            "ssh -G returned a value that cannot be saved safely."
        }
    }

    private enum MatchExecAction {
        case resolve
        case duplicate(String)
        case checkJumpHost
    }
}

enum SSHHostsEditorError: LocalizedError {
    case invalidInteger(String)
    case metadataUnavailable
    case invalidProxyJump

    var errorDescription: String? {
        switch self {
        case .invalidInteger(let label): "\(label) must be a whole number."
        case .metadataUnavailable: "SSH host metadata could not be loaded."
        case .invalidProxyJump: "Each jump host needs a HostName, and a port between 1 and 65535 if one is given."
        }
    }
}

struct SSHHostsView: View {
    @ObservedObject var model: SSHHostsEditorModel
    @ObservedObject private var catalog: SSHHostCatalog
    @State private var duplicateAlias = ""
    @State private var isPresentingPasswordSheet = false
    @State private var isPresentingDeleteConfirmation = false
    @State private var isPresentingTunnelDeleteConfirmation = false

    init(model: SSHHostsEditorModel) {
        self.model = model
        _catalog = ObservedObject(wrappedValue: model.catalog)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("CHOSTTY HOSTS") {
                    ForEach(model.filteredManagedHosts, id: \.hostID) { host in
                        Text(host.alias).tag(SSHHostsSelection.managed(host.hostID))
                            .onTapGesture { model.selectManaged(host) }
                    }
                }
                Section("FROM ~/.ssh/config") {
                    ForEach(model.readOnlyEntries) { entry in
                        Text(entry.displayName ?? entry.reference.alias)
                            .tag(SSHHostsSelection.readOnly(entry.reference))
                            .onTapGesture { model.selectReadOnly(entry) }
                    }
                }
                if !model.filteredOutsideHosts.isEmpty {
                    Section("Added outside Chostty") {
                        ForEach(model.filteredOutsideHosts) { host in
                            Text(host.alias)
                                .tag(SSHHostsSelection.outside(host))
                                .onTapGesture { model.selectOutside(host) }
                        }
                    }
                }
                Section {
                    ForEach(model.tunnelDefinitions) { definition in
                        SSHTunnelRow(definition: definition, tunnels: model.tunnels)
                            .tag(SSHHostsSelection.tunnel(definition.id))
                            .onTapGesture { model.selectTunnel(definition) }
                    }
                } header: {
                    HStack {
                        Text("TUNNELS")
                            .accessibilityIdentifier("ssh.tunnels-heading")
                        Spacer()
                        Button(
                            action: model.beginNewTunnel,
                            label: { Image(systemName: "plus") }
                        )
                            .buttonStyle(.borderless)
                            .disabled(model.tunnels == nil)
                            .accessibilityLabel("Add SSH tunnel")
                    }
                    .accessibilityElement(children: .contain)
                }
                if !model.configDiagnostics.isEmpty {
                    Section("CONFIG ISSUES") {
                        ForEach(Array(model.configDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Label(diagnostic.message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .searchable(text: $model.query, prompt: "Filter hosts")
            .onChange(of: model.selection) { _ in model.applySidebarSelection() }
            .toolbar {
                ToolbarItem {
                    Button(
                        action: model.beginNewHost,
                        label: { Image(systemName: "plus") }
                    )
                        .accessibilityLabel("Add SSH host")
                }
            }
            .frame(minWidth: 220)
        } detail: {
            detail
        }
        .alert("SSH configuration contains Match exec", isPresented: Binding(
            get: { model.needsMatchExecConsent },
            set: { if !$0 { model.dismissMatchExecConsent() } }
        )) {
            Button("Cancel", role: .cancel) { model.dismissMatchExecConsent() }
            Button("Continue") { model.confirmMatchExecConsent() }
        } message: {
            Text("Resolving can execute commands declared by this SSH configuration.")
        }
        .alert("Delete SSH Host?", isPresented: $isPresentingDeleteConfirmation) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteHostMessage)
        }
        .alert("Delete SSH Tunnel?", isPresented: $isPresentingTunnelDeleteConfirmation) {
            Button("Delete", role: .destructive) { model.deleteSelectedTunnel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tunnel definition will be removed.")
        }
        .alert("Allow connections from other computers?", isPresented: Binding(
            get: { model.needsBindConsent },
            set: { if !$0 { model.dismissBindConsent() } }
        )) {
            Button("Cancel", role: .cancel) { model.dismissBindConsent() }
            Button("Allow") { model.confirmBindConsent() }
        } message: {
            Text("This tunnel listens beyond this Mac, so other computers on the network can reach the forwarded port.")
        }
    }

    private var deleteHostMessage: String {
        let base = "The host will be removed. Any saved password for this host will also be removed."
        switch model.selectedHostRunningTunnelCount {
        case 0: return base
        case 1: return base + " Its running tunnel will be stopped first."
        case let count: return base + " Its \(count) running tunnels will be stopped first."
        }
    }

    @ViewBuilder private var detail: some View {
        if let tunnelDraft = model.tunnelDraft, let tunnels = model.tunnels {
            SSHTunnelEditor(model: model, tunnels: tunnels, draft: tunnelDraft) {
                isPresentingTunnelDeleteConfirmation = true
            }
        } else if let draft = model.draft {
            editor(draft)
        } else if let entry = model.selectedReadOnlyEntry {
            readOnly(entry)
        } else if let outside = model.selectedOutsideHost {
            outsideDetail(outside)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select an SSH Host")
                    .foregroundStyle(.secondary)
                errorBanner
            }
        }
    }

    // Keep the footer below the form so scrolled controls cannot cover Save.
    private func editor(_ draft: SSHHostDraft) -> some View {
        VStack(spacing: 0) {
            editorForm(draft)
            Divider()
            editorFooter
        }
        .overlay(alignment: .top) { errorBanner }
    }

    private func editorForm(_ draft: SSHHostDraft) -> some View {
        Form {
            Section {
                Text("Chostty-managed hosts are written only to this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let destination = model.resolvedDestination {
                    Text(destination.display)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Saved to \(model.savedToPath)")
                    .accessibilityIdentifier("ssh.saved-to")
            }
            Section("General") {
                TextField("Alias", text: model.draftBinding(\.alias, default: ""))
                    .accessibilityLabel("Alias")
                TextField("HostName", text: model.draftBinding(\.hostName, default: ""))
                    .accessibilityLabel("HostName")
                TextField("User", text: model.draftBinding(\.user, default: ""))
                    .accessibilityLabel("User")
                TextField("Port", text: model.draftBinding(\.port, default: ""))
                    .accessibilityLabel("Port")
                ForEach(Array(draft.identityFiles.indices), id: \.self) { index in
                    HStack {
                        TextField(
                            "IdentityFile",
                            text: model.identityFileBinding(at: index),
                            prompt: Text("~/.ssh/id_ed25519"))
                            .accessibilityLabel("IdentityFile")
                        Button("Choose…") { chooseIdentityFile(at: index) }
                        Button(
                            role: .destructive,
                            action: { model.removeIdentityFile(at: index) },
                            label: { Image(systemName: "minus.circle") }
                        )
                    }
                }
                Button("Add IdentityFile", action: model.addIdentityFile)
            }
            jumpHostSection(draft)
            Section("Authentication") {
                Picker("Authentication", selection: model.draftBinding(\.auth, default: .sshConfig)) {
                    Text("SSH config (keys, agent)").tag(SSHManagedHostAuth.sshConfig)
                    Text("Password in Keychain").tag(SSHManagedHostAuth.keychain)
                }
                if draft.auth == .sshConfig {
                    Text("SSH config (keys, agent)")
                        .foregroundStyle(.secondary)
                } else {
                    keychainAuthentication
                }
            }
            Section("Advanced") {
                Picker("IdentitiesOnly", selection: model.optionalBooleanBinding(\.identitiesOnly)) {
                    Text("Use SSH default").tag(0)
                    Text("Yes").tag(1)
                    Text("No").tag(2)
                }
                Picker("ForwardAgent", selection: model.optionalBooleanBinding(\.forwardAgent)) {
                    Text("Use SSH default").tag(0)
                    Text("Yes").tag(1)
                    Text("No").tag(2)
                }
                TextField("ServerAliveInterval", text: model.draftBinding(\.serverAliveInterval, default: ""))
                    .accessibilityLabel("ServerAliveInterval")
                if let host = model.selectedManagedHost, !host.otherLines.isEmpty {
                    Text("Other options — edit in external editor")
                    Text(host.otherLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section("Presentation") {
                TextField("Display name", text: model.draftBinding(\.displayName, default: ""))
                    .accessibilityLabel("Display name")
                if let host = model.selectedManagedHost {
                    let reference = SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias)
                    if model.isFavorite(reference) {
                        Button("Remove Favorite") { model.setFavorite(false, for: reference) }
                            .disabled(model.metadataSnapshot == nil)
                    } else {
                        Button("Add Favorite") { model.setFavorite(true, for: reference) }
                            .disabled(model.metadataSnapshot == nil)
                    }
                }
            }
            if !model.notCopied.isEmpty {
                Section("Not copied") {
                    Text(model.notCopied.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $isPresentingPasswordSheet) {
            SecurePasswordEntry(
                onSave: { secret in
                    model.savePassword(secret)
                    isPresentingPasswordSheet = false
                },
                onCancel: { isPresentingPasswordSheet = false }
            )
            .frame(width: 360, height: 130)
        }
        .formStyle(.grouped)
    }

    private func jumpHostSection(_ draft: SSHHostDraft) -> some View {
        Section {
            Picker("Jump host", selection: model.jumpHostChoiceBinding) {
                Text("None").tag(SSHJumpHostChoice.none)
                Text("Custom").tag(SSHJumpHostChoice.custom)
                if !model.jumpHostChoices.isEmpty {
                    Divider()
                    ForEach(model.jumpHostChoices, id: \.self) { alias in
                        Text(alias).tag(SSHJumpHostChoice.host(alias))
                    }
                }
            }
            .accessibilityIdentifier("ssh.jump-host")
            if model.jumpHostChoice == .custom {
                if draft.proxyJump.contains(",") {
                    TextField(
                        "ProxyJump",
                        text: model.draftBinding(\.proxyJump, default: ""),
                        prompt: Text("bastion,user@gateway:2222"))
                        .accessibilityLabel("ProxyJump")
                } else {
                    TextField("Jump User", text: model.jumpHopBinding(\.user), prompt: Text("From SSH config"))
                        .accessibilityLabel("Jump User")
                    TextField("Jump HostName", text: model.jumpHopBinding(\.host), prompt: Text("bastion.example.com"))
                        .accessibilityLabel("Jump HostName")
                    TextField("Jump Port", text: model.jumpHopBinding(\.port), prompt: Text("22"))
                        .accessibilityLabel("Jump Port")
                }
            }
            if model.jumpHostChoice != .none {
                HStack {
                    Button("Check Jump Host") { model.checkJumpHost() }
                        .disabled(!model.canCheckJumpHost)
                    if let check = model.currentJumpHostCheck, check.result == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                if draft.proxyJump.contains(",") {
                    Text("Only a single jump host can be checked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let result = model.currentJumpHostCheck?.result {
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(result.succeeded ? .green : .orange)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ssh.jump-check-result")
                }
            }
        } header: {
            Text("ProxyJump")
        } footer: {
            Text("Connects through this host first. To give the jump host its own key or options, add it as a host and choose it here. A jump host password is typed in the terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseIdentityFile(at index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
        panel.message = "Choose a private key file."
        panel.prompt = "Choose"
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.setIdentityFile(url, at: index)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            panel.begin(completionHandler: apply)
        }
    }

    private var editorFooter: some View {
        HStack {
            if model.changedOnDisk {
                Button("Reload", action: model.reload)
                Button("Overwrite") { model.save(overwritingExternalChanges: true) }
            }
            if model.selectedManagedHost != nil {
                Button("Connect", action: model.connectSelected)
                    .disabled(!model.canConnect)
                Button("Resolve with ssh -G…") { model.resolveSelected() }
            }
            Spacer()
            if model.selectedManagedHost != nil {
                Button("Delete…", role: .destructive) { isPresentingDeleteConfirmation = true }
                    .disabled(!model.canDelete)
            }
            Button("Save") { model.save() }
                .disabled(!model.canSave)
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder private var keychainAuthentication: some View {
        Text(model.keychainEligibilityDescription ?? "Save host changes first, then add a password.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Chostty answers this host's password prompt from the Keychain when it connects with /usr/bin/ssh. For key passphrases, use UseKeychain yes and AddKeysToAgent yes with Apple OpenSSH.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let warning = model.passwordWarning {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        switch model.passwordStatus {
        case .unavailableUntilHostSaved:
            Text("Save host changes first.")
                .font(.caption)
        case .noSavedPassword:
            Button("Save Password…") { isPresentingPasswordSheet = true }
                .disabled(!model.canManagePassword)
        case .ready:
            HStack {
                Text("Saved password ready")
                Button("Replace Password…") { isPresentingPasswordSheet = true }
                    .disabled(!model.canManagePassword)
                Button("Remove Password", role: .destructive, action: model.removePassword)
                    .disabled(!model.canManagePassword)
            }
        case .needsConfirmation(let stored):
            VStack(alignment: .leading) {
                Text("Saved password needs confirmation")
                Button("Use for \(model.currentPasswordDestination)") {
                    model.confirmPasswordTarget()
                }
                .disabled(!model.canManagePassword)
                Button("Replace Password…") { isPresentingPasswordSheet = true }
                    .disabled(!model.canManagePassword)
                Text("Previously saved for \(stored.displayDestination)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .locked:
            Text("Saved password is locked.")
        case .denied:
            Text("Saved password access was denied.")
        case .unavailable:
            Text("Saved password status is unavailable.")
        }
    }

    private func readOnly(_ entry: SSHHostEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.displayName ?? entry.reference.alias).font(.title2)
            Text("From \(model.savedToPath(for: entry.definedIn)) · line \(entry.line)")
                .foregroundStyle(.secondary)
            if let destination = model.resolvedDestination ?? entry.resolved {
                Text(destination.display)
            }
            HStack {
                Button("Connect", action: model.connectSelected).disabled(!model.canConnect)
                Button("Resolve with ssh -G…") { model.resolveSelected() }
                Button("Open in External Editor", action: model.openSelectedInExternalEditor)
            }
            Divider()
            HStack {
                TextField("New alias", text: $duplicateAlias)
                    .accessibilityLabel("New alias")
                Button("Duplicate to Edit") { model.duplicateSelected(alias: duplicateAlias) }
            }
            if model.isFavorite(entry.reference) {
                Button("Remove Favorite") { model.setFavorite(false, for: entry.reference) }
                    .disabled(model.metadataSnapshot == nil)
            } else {
                Button("Add Favorite") { model.setFavorite(true, for: entry.reference) }
                    .disabled(model.metadataSnapshot == nil)
            }
            Spacer()
        }
        .padding()
        .overlay(alignment: .top) { errorBanner }
    }

    private func outsideDetail(_ host: SSHOutsideHost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(host.alias).font(.title2)
            Text("Added outside Chostty · \(model.savedToPath) · line \(host.line)")
                .foregroundStyle(.secondary)
            Text("This block has no Chostty ownership marker and is read-only.")
            Button("Open in External Editor", action: model.openSelectedInExternalEditor)
            Spacer()
        }
        .padding()
    }

    @ViewBuilder private var errorBanner: some View {
        if let message = model.errorMessage {
            Text(message)
                .font(.caption)
                .padding(8)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .padding()
        }
    }
}

private struct SecurePasswordEntry: NSViewRepresentable {
    let onSave: (SSHSecretBuffer) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: "Password")
        let field = NSSecureTextField()
        let save = NSButton(title: "Save Password", target: context.coordinator, action: #selector(Coordinator.save))
        let cancel = NSButton(title: "Cancel", target: context.coordinator, action: #selector(Coordinator.cancel))
        context.coordinator.field = field

        [label, field, save, cancel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            save.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
            save.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -8),
            cancel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator: NSObject {
        weak var field: NSSecureTextField?
        private let onSave: (SSHSecretBuffer) -> Void
        private let onCancel: () -> Void

        init(onSave: @escaping (SSHSecretBuffer) -> Void, onCancel: @escaping () -> Void) {
            self.onSave = onSave
            self.onCancel = onCancel
        }

        @objc func save() {
            guard let field else { return }
            let value = field.stringValue
            field.stringValue = ""
            guard !value.isEmpty else { return }
            var bytes = Array(value.utf8)
            defer {
                bytes.withUnsafeMutableBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    _ = memset_s(base, buffer.count, 0, buffer.count)
                }
            }
            let secret = bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) }
            onSave(secret)
        }

        @objc func cancel() {
            field?.stringValue = ""
            onCancel()
        }
    }
}

private struct SSHTunnelRow: View {
    let definition: SSHTunnelDefinition
    let tunnels: SSHTunnelController?

    var body: some View {
        if let tunnels {
            SSHLiveTunnelRow(definition: definition, tunnels: tunnels)
        } else {
            SSHTunnelRowContent(name: definition.name, phase: .stopped)
        }
    }
}

/// Observes the controller so the dot and status follow the running tunnel.
private struct SSHLiveTunnelRow: View {
    let definition: SSHTunnelDefinition
    @ObservedObject var tunnels: SSHTunnelController

    var body: some View {
        SSHTunnelRowContent(name: definition.name, phase: tunnels.manager.phase(for: definition.id))
    }
}

private struct SSHTunnelRowContent: View {
    let name: String
    let phase: SSHTunnelPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(SSHTunnelStatusColor.color(for: phase))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(name)
        }
        .accessibilityLabel("\(name), \(SSHTunnelController.status(for: phase))")
    }
}

enum SSHTunnelStatusColor {
    static func color(for phase: SSHTunnelPhase) -> Color {
        switch phase {
        case .ready, .runningUnconfirmed: .green
        case .failed: .red
        case .stopped, .starting, .authenticating, .stopping: .gray
        }
    }
}

private struct SSHTunnelEditor: View {
    @ObservedObject var model: SSHHostsEditorModel
    @ObservedObject var tunnels: SSHTunnelController
    let draft: SSHTunnelDraft
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Tunnel") {
                TextField("Name", text: model.tunnelDraftBinding(\.name, default: ""))
                Picker("Host", selection: model.tunnelDraftBinding(\.host, default: nil)) {
                    ForEach(model.tunnelHosts) { entry in
                        Text(entry.displayName ?? entry.reference.alias)
                            .tag(Optional(entry.reference))
                    }
                }
                Picker("Type", selection: model.tunnelDraftBinding(\.kind, default: .local)) {
                    Text("Local (-L)").tag(SSHTunnelDefinition.Kind.local)
                    Text("Remote (-R)").tag(SSHTunnelDefinition.Kind.remote)
                    Text("Dynamic (-D)").tag(SSHTunnelDefinition.Kind.dynamic)
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.selectedTunnelIsRunning)
            Section("Forwarding") {
                TextField("Bind address", text: model.tunnelDraftBinding(\.bindAddress, default: ""))
                TextField("Bind port", text: model.tunnelDraftBinding(\.bindPort, default: ""))
                if draft.kind != .dynamic {
                    TextField("Target host", text: model.tunnelDraftBinding(\.targetHost, default: ""))
                    TextField("Target port", text: model.tunnelDraftBinding(\.targetPort, default: ""))
                }
            }
            .disabled(model.selectedTunnelIsRunning)
            if let id = draft.id {
                Section("Status") {
                    statusContent(id)
                }
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                if model.selectedTunnelIsRunning {
                    Text("Stop the tunnel to edit it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if draft.id != nil {
                    Button("Delete…", role: .destructive, action: onDelete)
                        .disabled(!model.canDeleteTunnel)
                }
                Button("Save") { model.saveTunnel() }
                    .disabled(!model.canSaveTunnel)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func statusContent(_ id: UUID) -> some View {
        let phase = tunnels.manager.phase(for: id)
        HStack {
            Circle()
                .fill(SSHTunnelStatusColor.color(for: phase))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(SSHTunnelController.status(for: phase))
            Spacer()
            if tunnels.isRunning(id) {
                Button("Stop") { tunnels.stop(id) }
            } else {
                Button("Start") { tunnels.start(id) }
                    .disabled(startBlocker(id) != nil)
            }
        }
        if let blocker = startBlocker(id) {
            Text(blocker)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if tunnels.manager.channelFailures.contains(id) {
            Text(SSHTunnelStderrClassifier.channelFailureMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startBlocker(_ id: UUID) -> String? {
        tunnels.definition(id).flatMap(tunnels.startBlocker(for:))
    }
}
