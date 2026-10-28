import Combine
import Darwin
import Foundation

enum SSHHostRevalidation: Equatable {
    case valid
    case blocked(SSHReconnectBlock)
}

@MainActor
final class SSHHostCatalog: ObservableObject {
    @Published private(set) var snapshot: SSHConfigScanResult
    /// The last scan in config order; `snapshot` is this plus presentation
    /// metadata, so favorite changes re-sort from the original order.
    private var scanned: SSHConfigScanResult

    private let paths: SSHPaths
    private let fileSystem: any SSHFileSystem
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watchRefresh: DispatchWorkItem?
    private var isWatching = false
    private var displayNames: [UUID: String] = [:]
    private var favorites: Set<SSHHostReference> = []
    private var resolvedDestinations: [SSHHostReference: SSHResolvedDestination] = [:]

    init(paths: SSHPaths, fileSystem: any SSHFileSystem = LocalSSHFileSystem()) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.scanned = SSHConfigScanResult(entries: [], diagnostics: [], containsMatchExec: false, observations: [:])
        self.snapshot = scanned
    }

    func prewarm() {
        let paths = paths
        let fileSystem = fileSystem
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scan = Self.scan(paths: paths, fileSystem: fileSystem)
            DispatchQueue.main.async {
                self?.install(scan)
            }
        }
    }

    func refreshIfStale() {
        guard snapshot.observations.isEmpty ||
                !SSHConfigScanner.observationsAreCurrent(snapshot.observations, fileSystem: fileSystem)
        else { return }
        install(Self.scan(paths: paths, fileSystem: fileSystem))
    }

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        refreshIfStale()
        if watchers.isEmpty { refreshWatchers() }
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        watchRefresh?.cancel()
        watchRefresh = nil
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }

    func revalidate(_ reference: SSHHostReference) -> Bool {
        revalidation(for: reference) == .valid
    }

    func revalidation(for reference: SSHHostReference) -> SSHHostRevalidation {
        let fresh = Self.scan(paths: paths, fileSystem: fileSystem)
        install(fresh)
        return revalidation(for: reference, in: fresh)
    }

    func revalidation(for reference: SSHHostReference, in snapshot: SSHConfigScanResult) -> SSHHostRevalidation {
        guard case .success = SSHAlias.validate(reference.alias) else { return .blocked(.aliasInvalid) }
        switch reference.source {
        case .managed:
            if case .unreadable = snapshot.observations[paths.managedHostsFile.path] {
                return .blocked(.configUnreadable)
            }
        case .sshConfig:
            if case .unreadable = snapshot.observations[paths.userConfig.path] {
                return .blocked(.configUnreadable)
            }
        }
        guard snapshot.entries.contains(where: { $0.reference == reference }) else {
            return .blocked(.hostRemoved)
        }
        return .valid
    }

    func validateUniqueAlias(_ alias: String, excluding hostID: UUID?) throws {
        let validAlias: String
        switch SSHAlias.validate(alias) {
        case .success(let value):
            validAlias = value
        case .failure(let error):
            throw SSHStoreError.invalidAlias(error)
        }

        let managed = SSHConfigScanner.scan(root: paths.managedHostsFile, paths: paths, fileSystem: fileSystem)
        let user = SSHConfigScanner.scan(root: paths.userConfig, paths: paths, fileSystem: fileSystem)
        let system = SSHConfigScanner.scan(root: paths.systemConfig, paths: paths, fileSystem: fileSystem)
        for scan in [managed, user, system] {
            if let code = Self.unreadableCode(in: scan) {
                throw SSHStoreError.readFailed(code)
            }
        }

        let userOrSystemCollision = (user.entries + system.entries).contains {
            $0.reference.alias == validAlias
        }
        guard !userOrSystemCollision else { throw SSHStoreError.duplicateAlias(validAlias) }

        guard case .file? = managed.observations[paths.managedHostsFile.path] else {
            return
        }
        let contents: String
        do {
            contents = try fileSystem.contents(of: paths.managedHostsFile)
        } catch {
            throw SSHStoreError.readFailed(Self.errorCode(error))
        }
        let document = SSHConfigDocument(text: contents)
        let collision = document.blocks(matching: validAlias).contains { block in
            block.kind == .host &&
                block.hostPatterns.contains(validAlias) &&
                (hostID == nil || block.managedHostID != hostID)
        }
        guard !collision else { throw SSHStoreError.duplicateAlias(validAlias) }
    }

    func setPresentationMetadata(
        displayNames: [UUID: String],
        favorites: Set<SSHHostReference>
    ) {
        self.displayNames = displayNames
        self.favorites = favorites
        publishDecoratedSnapshot()
    }

    func updateResolvedDestination(
        _ destination: SSHResolvedDestination,
        for reference: SSHHostReference
    ) {
        resolvedDestinations[reference] = destination
        publishDecoratedSnapshot()
    }

    private func install(_ scan: SSHConfigScanResult) {
        scanned = scan
        snapshot = decorate(scan)
        if isWatching { refreshWatchers() }
    }

    private func publishDecoratedSnapshot() {
        snapshot = decorate(scanned)
    }

    private func decorate(_ scan: SSHConfigScanResult) -> SSHConfigScanResult {
        var scan = scan
        scan.entries = scan.entries.map { entry in
            var entry = entry
            if case .managed(let hostID) = entry.reference.source {
                entry.displayName = displayNames[hostID]
            }
            entry.isFavorite = favorites.contains(entry.reference)
            entry.resolved = resolvedDestinations[entry.reference]
            return entry
        }
        scan.entries = scan.entries.enumerated().sorted { left, right in
            if left.element.isFavorite != right.element.isFavorite {
                return left.element.isFavorite
            }
            return left.offset < right.offset
        }.map(\.element)
        return scan
    }

    private func refreshWatchers() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        guard fileSystem is LocalSSHFileSystem else { return }

        let paths = Set(snapshot.observations.keys).flatMap { path in
            [URL(fileURLWithPath: path), URL(fileURLWithPath: path).deletingLastPathComponent()]
        }
        watchers = paths.compactMap(makeWatcher)
    }

    private func makeWatcher(for url: URL) -> DispatchSourceFileSystemObject? {
        var watchedURL = url
        var descriptor = open(watchedURL.path, O_EVTONLY | O_CLOEXEC)
        while descriptor < 0, watchedURL.path != "/" {
            watchedURL.deleteLastPathComponent()
            descriptor = open(watchedURL.path, O_EVTONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleWatchRefresh()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    private func scheduleWatchRefresh() {
        watchRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isWatching else { return }
            self.install(Self.scan(paths: self.paths, fileSystem: self.fileSystem))
        }
        watchRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    nonisolated private static func scan(paths: SSHPaths, fileSystem: any SSHFileSystem) -> SSHConfigScanResult {
        let startedAt = Date()
        let managed = SSHConfigScanner.scan(root: paths.managedHostsFile, paths: paths, fileSystem: fileSystem)
        let user = SSHConfigScanner.scan(root: paths.userConfig, paths: paths, fileSystem: fileSystem)
        let system = SSHConfigScanner.scan(root: paths.systemConfig, paths: paths, fileSystem: fileSystem)
        var aliases = Set<String>()
        var entries: [SSHHostEntry] = []
        var diagnostics = managed.diagnostics.filter {
            if case .duplicateAlias = $0 { return false }
            return true
        }
        let managedEntries = managedEntries(paths: paths, fileSystem: fileSystem, observation: managed.observations[paths.managedHostsFile.path])

        for entry in managedEntries + user.entries + system.entries {
            if aliases.insert(entry.reference.alias).inserted {
                entries.append(entry)
            } else {
                diagnostics.append(.duplicateAlias(entry.reference.alias, entry.definedIn, entry.line))
            }
        }
        diagnostics += user.diagnostics
        diagnostics += system.diagnostics

        let scan = SSHConfigScanResult(
            entries: entries,
            diagnostics: diagnostics,
            containsMatchExec: managed.containsMatchExec || user.containsMatchExec || system.containsMatchExec,
            observations: managed.observations
                .merging(user.observations) { first, _ in first }
                .merging(system.observations) { first, _ in first }
        )
        let files = scan.observations.values.count { if case .file = $0 { return true }; return false }
        let missing = diagnostics.count { if case .missing = $0 { return true }; return false }
        let permissionDenied = diagnostics.count { if case .permissionDenied = $0 { return true }; return false }
        let includeCycle = diagnostics.count { if case .includeCycle = $0 { return true }; return false }
        let depthExceeded = diagnostics.count { if case .depthExceeded = $0 { return true }; return false }
        let unsupportedAlias = diagnostics.count { if case .unsupportedAlias = $0 { return true }; return false }
        let duplicateAlias = diagnostics.count { if case .duplicateAlias = $0 { return true }; return false }
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        SSHLog.logger.notice(
            "catalog.scanned files=\(files, privacy: .public) entries=\(scan.entries.count, privacy: .public) missing=\(missing, privacy: .public) permissionDenied=\(permissionDenied, privacy: .public) includeCycle=\(includeCycle, privacy: .public) depthExceeded=\(depthExceeded, privacy: .public) unsupportedAlias=\(unsupportedAlias, privacy: .public) duplicateAlias=\(duplicateAlias, privacy: .public) containsMatchExec=\(scan.containsMatchExec, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
        return scan
    }

    nonisolated private static func managedEntries(
        paths: SSHPaths,
        fileSystem: any SSHFileSystem,
        observation: SSHFileObservation?
    ) -> [SSHHostEntry] {
        guard case .file = observation,
              let contents = try? fileSystem.contents(of: paths.managedHostsFile)
        else {
            return []
        }
        let document = SSHConfigDocument(text: contents)
        let blocks = document.managedBlocks.compactMap { block -> (SSHConfigDocument.Block, SSHManagedHost)? in
            guard let host = try? document.managedHost(for: block) else { return nil }
            return (block, host)
        }
        let hostIDCounts = blocks.reduce(into: [UUID: Int]()) { counts, value in
            counts[value.1.hostID, default: 0] += 1
        }
        return blocks.compactMap { block, host in
            guard hostIDCounts[host.hostID] == 1 else { return nil }
            return SSHHostEntry(
                reference: SSHHostReference(source: .managed(hostID: host.hostID), alias: host.alias),
                definedIn: paths.managedHostsFile,
                line: block.line,
                siblingAliases: [host.alias],
                displayName: nil,
                isFavorite: false,
                resolved: nil
            )
        }
    }

    nonisolated private static func unreadableCode(in scan: SSHConfigScanResult) -> Int32? {
        scan.observations.keys.sorted().compactMap { path in
            if case .unreadable(let code) = scan.observations[path] {
                return code
            }
            return nil
        }.first
    }

    nonisolated private static func errorCode(_ error: Error) -> Int32 {
        if let error = error as? POSIXError {
            return Int32(error.errorCode)
        }
        return Int32(truncatingIfNeeded: (error as NSError).code)
    }
}
