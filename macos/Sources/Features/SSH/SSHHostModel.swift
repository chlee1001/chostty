import Foundation

enum SSHHostSource: Codable, Hashable, Sendable {
    case managed(hostID: UUID)
    case sshConfig
}

struct SSHHostReference: Codable, Hashable, Sendable {
    let source: SSHHostSource
    let alias: String
}

struct SSHResolvedDestination: Codable, Hashable, Sendable {
    let user: String?
    let hostName: String
    let port: Int

    var display: String {
        let identity = user.map { "\($0)@\(hostName)" } ?? hostName
        return port == 22 ? identity : "\(identity):\(port)"
    }
}

struct SSHHostEntry: Identifiable, Equatable, Sendable {
    let reference: SSHHostReference
    let definedIn: URL
    let line: Int
    let siblingAliases: [String]
    var displayName: String?
    var isFavorite: Bool
    var resolved: SSHResolvedDestination?

    var id: SSHHostReference { reference }
}

struct SSHPaneBinding: Codable, Equatable, Sendable {
    let reference: SSHHostReference
    var displayDestination: String?
}

struct SSHPaneLaunch: Equatable, Sendable {
    let binding: SSHPaneBinding
    let launchID: UUID
    let runtimeDirectory: URL
    let autoConnect: Bool
}

enum SSHPaneConnectionState: Equatable, Sendable {
    case waiting
    case connecting
    case connected
    case lost(exitStatus: Int32, everConnected: Bool)
}

enum SSHReconnectBlock: Equatable, Sendable {
    case hostRemoved
    case aliasInvalid
    case configUnreadable
}

struct SSHPaneStatus: Equatable, Sendable {
    var connection: SSHPaneConnectionState
    var reconnectBlock: SSHReconnectBlock?
}

struct SSHTabPresentation: Equatable {
    let alias: String
    let destination: String?
    let status: SSHPaneStatus
}

struct SSHPaths: Sendable {
    let home: URL
    let userConfig: URL
    let systemConfig: URL
    let runtimeRoot: URL
    let dataDirectory: URL
    let managedHostsFile: URL
    let metadataFile: URL

    init(
        home: URL,
        userConfig: URL? = nil,
        systemConfig: URL = URL(fileURLWithPath: "/etc/ssh/ssh_config"),
        runtimeRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.userConfig = userConfig ?? home.appendingPathComponent(".ssh/config")
        self.systemConfig = systemConfig
        self.runtimeRoot = runtimeRoot

        #if DEBUG
        if let override = environment["CHOSTTY_SSH_DATA_DIR"], !override.isEmpty {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = Self.defaultDataDirectory(home: home, environment: environment)
        }
        #else
        dataDirectory = Self.defaultDataDirectory(home: home, environment: environment)
        #endif
        managedHostsFile = dataDirectory.appendingPathComponent("hosts.conf")
        metadataFile = dataDirectory.appendingPathComponent("hosts.meta.json")
    }

    private static func defaultDataDirectory(home: URL, environment: [String: String]) -> URL {
        ConfigHome.directory(environment: environment, home: home)
            .appendingPathComponent("chostty/ssh", isDirectory: true)
    }
}
