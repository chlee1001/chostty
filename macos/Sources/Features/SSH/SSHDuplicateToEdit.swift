import Foundation

enum SSHDuplicateToEditError: Error, Equatable, Sendable {
    case matchExecConsentRequired
    case invalidAlias(SSHAliasError)
    case aliasMustDiffer
    case resolutionFailed
    case invalidResolvedValue
}

struct SSHDuplicateToEditResult: Equatable, Sendable {
    let host: SSHManagedHost
    let notCopied: [String]
}

final class SSHDuplicateToEdit: @unchecked Sendable {
    private static let copiedOptions: Set<String> = [
        "hostname",
        "user",
        "port",
        "identityfile",
        "proxyjump",
        "identitiesonly",
        "forwardagent",
        "serveraliveinterval",
    ]

    private let resolver: any SSHResolving

    init(resolver: any SSHResolving = SSHResolver()) {
        self.resolver = resolver
    }

    func duplicate(
        reference: SSHHostReference,
        paths: SSHPaths,
        observations: [String: SSHFileObservation],
        containsMatchExec: Bool,
        allowMatchExec: Bool = false,
        alias: String,
        completion: @escaping @Sendable (Swift.Result<SSHDuplicateToEditResult, SSHDuplicateToEditError>) -> Void
    ) {
        switch SSHAlias.validate(alias) {
        case .success:
            break
        case .failure(let error):
            completion(.failure(.invalidAlias(error)))
            return
        }
        guard alias != reference.alias else {
            completion(.failure(.aliasMustDiffer))
            return
        }
        guard !containsMatchExec || allowMatchExec else {
            completion(.failure(.matchExecConsentRequired))
            return
        }

        resolver.resolve(
            reference: reference,
            paths: paths,
            observations: observations,
            containsMatchExec: containsMatchExec,
            reason: .duplicate(allowMatchExec: allowMatchExec)
        ) { [resolver] original in
            guard let original else {
                completion(.failure(.resolutionFailed))
                return
            }
            resolver.resolveBaseline(alias: reference.alias) { baseline in
                guard let baseline else {
                    completion(.failure(.resolutionFailed))
                    return
                }
                do {
                    completion(.success(try Self.copy(
                        original: original,
                        baseline: baseline,
                        alias: alias)))
                } catch {
                    completion(.failure(.invalidResolvedValue))
                }
            }
        }
    }

    private static func copy(
        original: SSHResolver.Result,
        baseline: SSHResolver.Result,
        alias: String
    ) throws -> SSHDuplicateToEditResult {
        let originalOptions = original.options
        let baselineOptions = baseline.options
        let differs: (String) -> Bool = { originalOptions[$0] != baselineOptions[$0] }
        let identitiesOnly: Bool?
        if differs("identitiesonly") {
            guard let value = boolValue(originalOptions["identitiesonly"]?.last) else {
                throw SSHDuplicateToEditError.invalidResolvedValue
            }
            identitiesOnly = value
        } else {
            identitiesOnly = nil
        }
        let forwardAgent: Bool?
        if differs("forwardagent") {
            guard let value = boolValue(originalOptions["forwardagent"]?.last) else {
                throw SSHDuplicateToEditError.invalidResolvedValue
            }
            forwardAgent = value
        } else {
            forwardAgent = nil
        }
        let serverAliveInterval: Int?
        if differs("serveraliveinterval") {
            guard let value = Int(originalOptions["serveraliveinterval"]?.last ?? "") else {
                throw SSHDuplicateToEditError.invalidResolvedValue
            }
            serverAliveInterval = value
        } else {
            serverAliveInterval = nil
        }

        let host = try SSHManagedHost(
            hostID: UUID(),
            alias: alias,
            hostName: original.destination.hostName,
            user: differs("user") ? originalOptions["user"]?.last : nil,
            port: differs("port") ? original.destination.port : nil,
            identityFiles: differs("identityfile") ? originalOptions["identityfile"] ?? [] : [],
            proxyJump: differs("proxyjump") ? originalOptions["proxyjump"]?.last : nil,
            identitiesOnly: identitiesOnly,
            forwardAgent: forwardAgent,
            serverAliveInterval: serverAliveInterval,
            otherLines: [])

        let notCopied = Set(originalOptions.keys)
            .union(baselineOptions.keys)
            .filter { !copiedOptions.contains($0) && originalOptions[$0] != baselineOptions[$0] }
            .sorted()
        return SSHDuplicateToEditResult(host: host, notCopied: notCopied)
    }

    private static func boolValue(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "yes": true
        case "no": false
        default: nil
        }
    }
}
