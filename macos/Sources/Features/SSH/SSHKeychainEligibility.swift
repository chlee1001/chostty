import Foundation

enum SSHKeychainEligibility: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case missingUser
        case missingHostName
        case missingPort
        case precededByHost(line: Int)
        case precededByMatch(line: Int)
        case scopeOverride(line: Int)
        case includedScope(line: Int)
        case invalidConfiguration
        case blockNotFound
    }

    case eligible(SSHTargetFingerprint)
    case ineligible(Reason)

    static func evaluate(document: SSHConfigDocument, hostID: UUID) -> Self {
        let owned = document.managedBlocks.filter { $0.managedHostID == hostID }
        guard owned.count == 1,
              let block = owned.first,
              block.kind == .host,
              block.hostPatterns.count == 1
        else {
            return logged(.ineligible(.blockNotFound))
        }
        guard let text = String(data: document.data, encoding: .utf8) else {
            return logged(.ineligible(.invalidConfiguration))
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard block.line <= lines.count else {
            return logged(.ineligible(.invalidConfiguration))
        }
        let directives = lines.map { SSHConfigDocument.directive(in: String($0)) }
        let firstStructural = directives.firstIndex {
            $0?.keyword.caseInsensitiveCompare("host") == .orderedSame ||
                $0?.keyword.caseInsensitiveCompare("match") == .orderedSame
        }
        guard let firstStructural else {
            return logged(.ineligible(.invalidConfiguration))
        }
        for index in 0..<firstStructural {
            guard let keyword = directives[index]?.keyword.lowercased() else { continue }
            if keyword == "include" {
                return logged(.ineligible(.includedScope(line: index + 1)))
            }
            if ["user", "hostname", "port"].contains(keyword) {
                return logged(.ineligible(.scopeOverride(line: index + 1)))
            }
        }
        for index in firstStructural..<(block.line - 1)
            where directives[index]?.keyword.caseInsensitiveCompare("include") == .orderedSame {
            return logged(.ineligible(.includedScope(line: index + 1)))
        }

        var explicitFields: Set<String> = []
        let ownedHeader = block.line - 1
        var index = ownedHeader + 1
        while index < directives.count {
            guard let directive = directives[index] else {
                index += 1
                continue
            }
            let keyword = directive.keyword.lowercased()
            if keyword == "host" || keyword == "match" { break }
            if keyword == "include",
               !Set(["user", "hostname", "port"]).isSubset(of: explicitFields) {
                return logged(.ineligible(.includedScope(line: index + 1)))
            }
            if ["user", "hostname", "port"].contains(keyword) {
                explicitFields.insert(keyword)
            }
            index += 1
        }

        let matching = document.blocks(matching: block.hostPatterns[0])
        guard let first = matching.first else { return logged(.ineligible(.blockNotFound)) }
        guard first == block else {
            switch first.kind {
            case .host: return logged(.ineligible(.precededByHost(line: first.line)))
            case .match: return logged(.ineligible(.precededByMatch(line: first.line)))
            }
        }

        let explicit = Set(block.lines.dropFirst().compactMap { SSHConfigDocument.directive(in: $0)?.keyword.lowercased() })
        guard explicit.contains("user") else { return logged(.ineligible(.missingUser)) }
        guard explicit.contains("hostname") else { return logged(.ineligible(.missingHostName)) }
        guard explicit.contains("port") else { return logged(.ineligible(.missingPort)) }

        do {
            let host = try document.managedHost(for: block)
            guard let user = host.user else { return logged(.ineligible(.missingUser)) }
            guard let port = host.port else { return logged(.ineligible(.missingPort)) }
            return logged(.eligible(try SSHTargetFingerprint(
                hostID: host.hostID,
                user: user,
                hostName: host.hostName,
                port: port)))
        } catch {
            return logged(.ineligible(.blockNotFound))
        }
    }

    private static func logged(_ eligibility: Self) -> Self {
        let outcome: String
        let reason: String
        switch eligibility {
        case .eligible:
            outcome = "eligible"
            reason = "none"
        case .ineligible(let value):
            outcome = "ineligible"
            switch value {
            case .missingUser: reason = "missingUser"
            case .missingHostName: reason = "missingHostName"
            case .missingPort: reason = "missingPort"
            case .precededByHost: reason = "precededByHost"
            case .precededByMatch: reason = "precededByMatch"
            case .scopeOverride: reason = "scopeOverride"
            case .includedScope: reason = "includedScope"
            case .invalidConfiguration: reason = "invalidConfiguration"
            case .blockNotFound: reason = "blockNotFound"
            }
        }
        SSHLog.logger.notice(
            "keychain.eligibility outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public)")
        return eligibility
    }
}
