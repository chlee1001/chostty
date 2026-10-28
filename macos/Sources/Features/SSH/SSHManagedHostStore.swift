import Foundation

struct SSHManagedHost: Equatable, Sendable {
    let hostID: UUID
    var alias: String
    var hostName: String
    var user: String?
    var port: Int?
    var identityFiles: [String]
    var proxyJump: String?
    var identitiesOnly: Bool?
    var forwardAgent: Bool?
    var serverAliveInterval: Int?
    let otherLines: [String]

    init(
        hostID: UUID,
        alias: String,
        hostName: String,
        user: String? = nil,
        port: Int? = nil,
        identityFiles: [String] = [],
        proxyJump: String? = nil,
        identitiesOnly: Bool? = nil,
        forwardAgent: Bool? = nil,
        serverAliveInterval: Int? = nil,
        otherLines: [String] = []
    ) throws {
        let validAlias: String
        switch SSHAlias.validate(alias) {
        case .success(let value):
            validAlias = value
        case .failure(let error):
            throw SSHStoreError.invalidAlias(error)
        }
        try Self.validateScalar(hostName)
        try user.map(Self.validateScalar)
        try proxyJump.map(Self.validateScalar)
        guard port.map({ (1...65535).contains($0) }) ?? true else {
            throw SSHStoreError.invalidPort
        }
        for identityFile in identityFiles {
            try Self.validateScalar(identityFile)
            guard identityFile.hasPrefix("/") || identityFile.hasPrefix("~") else {
                throw SSHStoreError.invalidIdentityFile(identityFile)
            }
        }
        guard serverAliveInterval.map({ $0 >= 0 }) ?? true else {
            throw SSHStoreError.invalidPort
        }
        guard otherLines.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw SSHStoreError.invalidOtherLine
        }

        self.hostID = hostID
        self.alias = validAlias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
        self.identitiesOnly = identitiesOnly
        self.forwardAgent = forwardAgent
        self.serverAliveInterval = serverAliveInterval
        self.otherLines = otherLines
    }

    private static func validateScalar(_ value: String) throws {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else {
            throw SSHStoreError.invalidScalarValue(value)
        }
    }
}

struct SSHManagedHostSnapshot: Equatable, Sendable {
    let hosts: [SSHManagedHost]
    /// nil records that the file was missing when this snapshot was loaded.
    let hash: Data?
}

final class SSHManagedHostStore {
    private let paths: SSHPaths
    private let writer: SSHSecureFileWriter

    init(paths: SSHPaths, writer: SSHSecureFileWriter = SSHSecureFileWriter()) {
        self.paths = paths
        self.writer = writer
    }

    func load() throws -> SSHManagedHostSnapshot {
        let contents = try writer.read(at: paths.managedHostsFile)
        let document = SSHConfigDocument(data: contents.data ?? Data())
        let hosts = try document.managedBlocks.map(document.managedHost)
        return SSHManagedHostSnapshot(hosts: hosts, hash: contents.hash)
    }

    @discardableResult
    func save(_ host: SSHManagedHost, expectedHash: Data?) throws -> SSHManagedHostSnapshot {
        var result = "ioError"
        defer {
            SSHLog.logger.notice(
                "store.saved target=hosts result=\(result, privacy: .public)")
        }
        do {
            let contents = try writer.read(at: paths.managedHostsFile)
            guard contents.hash == expectedHash else { throw SSHStoreError.changedOnDisk }

            var document = SSHConfigDocument(data: contents.data ?? Data())
            let existingHosts = try document.managedBlocks.map(document.managedHost)
            if existingHosts.contains(where: { $0.alias == host.alias && $0.hostID != host.hostID }) {
                throw SSHStoreError.duplicateAlias(host.alias)
            }
            try document.upsertManagedHost(host)
            let data = document.dataForManagedChanges()
            try writer.write(data, to: paths.managedHostsFile, expectedHash: expectedHash)
            let written = SSHConfigDocument(data: data)
            let snapshot = SSHManagedHostSnapshot(
                hosts: try written.managedBlocks.map(written.managedHost),
                hash: SSHSecureFileWriter.hash(of: data))
            result = "ok"
            return snapshot
        } catch {
            if (error as? SSHStoreError) == .changedOnDisk {
                result = "conflict"
            }
            throw error
        }
    }

    @discardableResult
    func delete(hostID: UUID, expectedHash: Data?) throws -> SSHManagedHostSnapshot {
        var result = "ioError"
        defer {
            SSHLog.logger.notice(
                "store.saved target=hosts result=\(result, privacy: .public)")
        }
        do {
            let contents = try writer.read(at: paths.managedHostsFile)
            guard contents.hash == expectedHash else { throw SSHStoreError.changedOnDisk }

            var document = SSHConfigDocument(data: contents.data ?? Data())
            try document.deleteManagedHost(id: hostID)
            let data = document.dataForManagedChanges()
            try writer.write(data, to: paths.managedHostsFile, expectedHash: expectedHash)
            let written = SSHConfigDocument(data: data)
            let snapshot = SSHManagedHostSnapshot(
                hosts: try written.managedBlocks.map(written.managedHost),
                hash: SSHSecureFileWriter.hash(of: data))
            result = "ok"
            return snapshot
        } catch {
            if (error as? SSHStoreError) == .changedOnDisk {
                result = "conflict"
            }
            throw error
        }
    }
}
