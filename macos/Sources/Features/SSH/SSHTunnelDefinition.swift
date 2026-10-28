import Foundation

enum SSHTunnelDefinitionError: Error, Equatable, Sendable, LocalizedError {
    case invalidName
    case invalidHostAlias(SSHAliasError)
    case invalidBindAddress
    case invalidBindPort
    case missingTarget
    case unexpectedTarget
    case invalidTargetHost
    case invalidTargetPort
    case externalBindConsentRequired
    case invalidExternalBindConsent

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "The tunnel name is invalid."
        case .invalidHostAlias:
            return "The tunnel host alias is invalid."
        case .invalidBindAddress:
            return "The bind address is invalid."
        case .invalidBindPort:
            return "The bind port must be between 1 and 65535."
        case .missingTarget:
            return "This tunnel requires a target host and port."
        case .unexpectedTarget:
            return "A dynamic tunnel cannot have a target host or port."
        case .invalidTargetHost:
            return "The target host is invalid."
        case .invalidTargetPort:
            return "The target port must be between 1 and 65535."
        case .externalBindConsentRequired:
            return "External tunnel binds require consent."
        case .invalidExternalBindConsent:
            return "The external bind consent does not match this tunnel."
        }
    }
}

struct SSHTunnelDefinition: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case local
        case remote
        case dynamic
    }

    let id: UUID
    var name: String
    var host: SSHHostReference
    var kind: Kind
    var bindAddress: String = "127.0.0.1"
    var bindPort: Int
    var targetHost: String?
    var targetPort: Int?
    var externalBindConsent: SSHBindConsent?

    func validate() throws {
        guard !name.isEmpty,
              name.count <= 256,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw SSHTunnelDefinitionError.invalidName
        }

        switch SSHAlias.validate(host.alias) {
        case .success:
            break
        case .failure(let error):
            throw SSHTunnelDefinitionError.invalidHostAlias(error)
        }

        guard Self.validEndpointHost(bindAddress) else {
            throw SSHTunnelDefinitionError.invalidBindAddress
        }
        guard (1...65535).contains(bindPort) else {
            throw SSHTunnelDefinitionError.invalidBindPort
        }

        switch kind {
        case .local, .remote:
            guard let targetHost, let targetPort else {
                throw SSHTunnelDefinitionError.missingTarget
            }
            guard Self.validEndpointHost(targetHost) else {
                throw SSHTunnelDefinitionError.invalidTargetHost
            }
            guard (1...65535).contains(targetPort) else {
                throw SSHTunnelDefinitionError.invalidTargetPort
            }
        case .dynamic:
            guard targetHost == nil, targetPort == nil else {
                throw SSHTunnelDefinitionError.unexpectedTarget
            }
        }

        if let consent = externalBindConsent,
           !consent.matches(address: bindAddress, port: bindPort, kind: kind) {
            throw SSHTunnelDefinitionError.invalidExternalBindConsent
        }
        if SSHBindConsent.requiresConsent(for: bindAddress), externalBindConsent == nil {
            throw SSHTunnelDefinitionError.externalBindConsentRequired
        }
    }

    private static func validEndpointHost(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }
    }
}

enum SSHTunnelPhase: Equatable, Sendable {
    case stopped
    case starting
    /// ssh is waiting for an answer from the user.
    case authenticating
    case ready
    case runningUnconfirmed
    case stopping
    case failed(SSHTunnelFailure)
}
