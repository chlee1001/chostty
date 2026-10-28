import Foundation

enum SSHManagedHostAuth: String, Codable, Equatable, Hashable, Sendable {
    case sshConfig
    case keychain
}

enum SSHHostMetadataError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidDisplayName
    case duplicateTunnelID(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "The SSH host metadata version is unsupported."
        case .invalidDisplayName:
            return "An SSH host display name is invalid."
        case .duplicateTunnelID:
            return "Tunnel IDs must be unique."
        }
    }
}

struct SSHManagedHostMetadata: Codable, Equatable, Sendable {
    static let maximumDisplayNameLength = 256

    var displayName: String?
    var auth: SSHManagedHostAuth

    init(displayName: String? = nil, auth: SSHManagedHostAuth = .sshConfig) throws {
        try Self.validate(displayName: displayName)
        self.displayName = displayName
        self.auth = auth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            auth: try container.decodeIfPresent(SSHManagedHostAuth.self, forKey: .auth) ?? .sshConfig
        )
    }

    fileprivate func validate() throws {
        try Self.validate(displayName: displayName)
    }

    private static func validate(displayName: String?) throws {
        guard let displayName else { return }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.count <= maximumDisplayNameLength,
              displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw SSHHostMetadataError.invalidDisplayName
        }
    }
}

struct SSHHostMetadataFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version
        case hosts
        case favorites
        case tunnels
    }

    var version: Int
    var hosts: [UUID: SSHManagedHostMetadata]
    var favorites: [SSHHostReference]
    var tunnels: [SSHTunnelDefinition]

    init(
        version: Int = currentVersion,
        hosts: [UUID: SSHManagedHostMetadata] = [:],
        favorites: [SSHHostReference] = [],
        tunnels: [SSHTunnelDefinition] = []
    ) throws {
        guard version == Self.currentVersion else {
            throw SSHHostMetadataError.unsupportedVersion(version)
        }
        self.version = version
        self.hosts = hosts
        self.favorites = favorites
        self.tunnels = tunnels
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedHosts = try container.decodeIfPresent([String: SSHManagedHostMetadata].self, forKey: .hosts) ?? [:]
        var hosts: [UUID: SSHManagedHostMetadata] = [:]
        for (key, metadata) in encodedHosts {
            guard let hostID = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .hosts,
                    in: container,
                    debugDescription: "Metadata host key is not a UUID: \(key)"
                )
            }
            hosts[hostID] = metadata
        }
        try self.init(
            version: try container.decode(Int.self, forKey: .version),
            hosts: hosts,
            favorites: try container.decodeIfPresent([SSHHostReference].self, forKey: .favorites) ?? [],
            tunnels: try container.decodeIfPresent([SSHTunnelDefinition].self, forKey: .tunnels) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(
            Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.uuidString, $0.value) }),
            forKey: .hosts
        )
        try container.encode(favorites, forKey: .favorites)
        try container.encode(tunnels, forKey: .tunnels)
    }

    fileprivate func validate() throws {
        guard version == Self.currentVersion else {
            throw SSHHostMetadataError.unsupportedVersion(version)
        }
        for metadata in hosts.values {
            try metadata.validate()
        }
        var tunnelIDs = Set<UUID>()
        for tunnel in tunnels {
            guard tunnelIDs.insert(tunnel.id).inserted else {
                throw SSHHostMetadataError.duplicateTunnelID(tunnel.id)
            }
            try tunnel.validate()
        }
    }
}

struct SSHHostMetadataSnapshot: Equatable, Sendable {
    let metadata: SSHHostMetadataFile
    /// nil records that the metadata file was missing when this snapshot was loaded.
    let hash: Data?
}

final class SSHHostMetadataStore {
    private let paths: SSHPaths
    private let writer: SSHSecureFileWriter

    init(paths: SSHPaths, writer: SSHSecureFileWriter = SSHSecureFileWriter()) {
        self.paths = paths
        self.writer = writer
    }

    func load() throws -> SSHHostMetadataSnapshot {
        let contents = try writer.read(at: paths.metadataFile)
        let metadata: SSHHostMetadataFile
        if let data = contents.data {
            metadata = try JSONDecoder().decode(SSHHostMetadataFile.self, from: data)
        } else {
            metadata = try SSHHostMetadataFile()
        }
        return SSHHostMetadataSnapshot(metadata: metadata, hash: contents.hash)
    }

    @discardableResult
    func save(_ metadata: SSHHostMetadataFile, expectedHash: Data?) throws -> SSHHostMetadataSnapshot {
        var result = "ioError"
        defer {
            SSHLog.logger.notice(
                "store.saved target=meta result=\(result, privacy: .public)")
        }
        do {
            try metadata.validate()
            let contents = try writer.read(at: paths.metadataFile)
            guard contents.hash == expectedHash else { throw SSHStoreError.changedOnDisk }
            if let existingData = contents.data {
                _ = try JSONDecoder().decode(SSHHostMetadataFile.self, from: existingData)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try writer.write(data, to: paths.metadataFile, expectedHash: expectedHash)
            let snapshot = SSHHostMetadataSnapshot(metadata: metadata, hash: SSHSecureFileWriter.hash(of: data))
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
