import Foundation

struct SSHConfigDocument {
    enum BlockKind: Equatable, Sendable {
        case host
        case match
    }

    struct Block: Equatable, Sendable {
        let kind: BlockKind
        let line: Int
        let hostPatterns: [String]
        let managedHostID: UUID?
        let lines: [String]
        fileprivate let range: Range<Int>
    }

    private static let ownershipPrefix = "# chostty-host-id: "
    private var lines: [Data]

    init(data: Data = Data()) {
        lines = Self.splitLines(data)
    }

    init(text: String) {
        self.init(data: Data(text.utf8))
    }

    var data: Data {
        lines.reduce(into: Data()) { $0.append($1) }
    }

    var managedBlocks: [Block] {
        parsedBlocks.filter { $0.managedHostID != nil }
    }

    func blocks(matching alias: String) -> [Block] {
        parsedBlocks.filter { block in
            switch block.kind {
            case .match:
                return true
            case .host:
                return Self.hostPatterns(block.hostPatterns, match: alias)
            }
        }
    }

    func managedHost(for block: Block) throws -> SSHManagedHost {
        guard block.kind == .host,
              let hostID = block.managedHostID,
              block.hostPatterns.count == 1
        else {
            throw SSHStoreError.invalidManagedBlock(block.managedHostID ?? UUID())
        }
        guard lines[block.range].allSatisfy({ String(bytes: $0, encoding: .utf8) != nil }) else {
            throw SSHStoreError.invalidManagedBlock(hostID)
        }

        var hostName: String?
        var user: String?
        var port: Int?
        var identityFiles: [String] = []
        var proxyJump: String?
        var identitiesOnly: Bool?
        var forwardAgent: Bool?
        var serverAliveInterval: Int?
        var otherLines: [String] = []

        for rawLine in block.lines.dropFirst() {
            guard let directive = Self.directive(in: rawLine) else {
                otherLines.append(rawLine)
                continue
            }
            let value = directive.values.first
            switch directive.keyword.lowercased() {
            case "hostname":
                guard directive.values.count == 1, let value, Self.isValidScalar(value) else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if hostName == nil { hostName = value }
            case "user":
                guard directive.values.count == 1, let value, Self.isValidScalar(value) else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if user == nil { user = value }
            case "port":
                guard directive.values.count == 1,
                      let value,
                      let parsed = Int(value),
                      (1...65535).contains(parsed)
                else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if port == nil { port = parsed }
            case "identityfile":
                guard directive.values.count == 1,
                      let value,
                      Self.isValidScalar(value),
                      value.hasPrefix("/") || value.hasPrefix("~")
                else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                identityFiles.append(value)
            case "proxyjump":
                guard directive.values.count == 1, let value, Self.isValidScalar(value) else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if proxyJump == nil { proxyJump = value }
            case "identitiesonly":
                guard directive.values.count == 1, let value, let parsed = Self.boolValue(value) else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if identitiesOnly == nil { identitiesOnly = parsed }
            case "forwardagent":
                guard directive.values.count == 1, let value, let parsed = Self.boolValue(value) else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if forwardAgent == nil { forwardAgent = parsed }
            case "serveraliveinterval":
                guard directive.values.count == 1, let value, let parsed = Int(value), parsed >= 0 else {
                    throw SSHStoreError.invalidManagedBlock(hostID)
                }
                if serverAliveInterval == nil { serverAliveInterval = parsed }
            default:
                otherLines.append(rawLine)
            }
        }

        guard let hostName else { throw SSHStoreError.invalidManagedBlock(hostID) }
        return try SSHManagedHost(
            hostID: hostID,
            alias: block.hostPatterns[0],
            hostName: hostName,
            user: user,
            port: port,
            identityFiles: identityFiles,
            proxyJump: proxyJump,
            identitiesOnly: identitiesOnly,
            forwardAgent: forwardAgent,
            serverAliveInterval: serverAliveInterval,
            otherLines: otherLines
        )
    }

    mutating func upsertManagedHost(_ host: SSHManagedHost) throws {
        let host = try SSHManagedHost(
            hostID: host.hostID,
            alias: host.alias,
            hostName: host.hostName,
            user: host.user,
            port: host.port,
            identityFiles: host.identityFiles,
            proxyJump: host.proxyJump,
            identitiesOnly: host.identitiesOnly,
            forwardAgent: host.forwardAgent,
            serverAliveInterval: host.serverAliveInterval,
            otherLines: host.otherLines)
        let replacement = Self.renderedLines(for: host)
        let matches = managedBlocks.filter { $0.managedHostID == host.hostID }
        if matches.count > 1 {
            throw SSHStoreError.invalidManagedBlock(host.hostID)
        }
        if let existing = matches.first {
            lines.replaceSubrange(existing.range, with: replacement)
        } else {
            let insertion = trailingTailStart ?? lines.endIndex
            var added = replacement
            if insertion > lines.startIndex, !Self.content(of: lines[insertion - 1]).isEmpty {
                added.insert(Data("\n".utf8), at: added.startIndex)
            }
            if trailingTailStart != nil {
                added.append(Data("\n".utf8))
            }
            lines.insert(contentsOf: added, at: insertion)
        }
    }

    mutating func deleteManagedHost(id hostID: UUID) throws {
        let matches = managedBlocks.filter { $0.managedHostID == hostID }
        guard matches.count <= 1 else { throw SSHStoreError.invalidManagedBlock(hostID) }
        guard let block = matches.first else { throw SSHStoreError.invalidManagedBlock(hostID) }
        lines.removeSubrange(block.range)
    }

    func dataForManagedChanges() -> Data {
        var result = self
        result.ensureManagedTail()
        return result.data
    }

    private var parsedBlocks: [Block] {
        let starts = lines.indices.filter { index in
            guard let directive = Self.directive(in: Self.content(of: lines[index])) else { return false }
            let keyword = directive.keyword.lowercased()
            return keyword == "host" || keyword == "match"
        }
        return starts.enumerated().map { offset, start in
            var end = offset + 1 < starts.count ? starts[offset + 1] : lines.endIndex
            if end < lines.endIndex,
               Self.directive(in: Self.content(of: lines[end]))?.keyword.lowercased() == "host",
               Self.ownedHostID(in: Self.content(of: lines[end - 1])) != nil {
                end -= 1
            }
            let header = Self.directive(in: Self.content(of: lines[start]))!
            let kind: BlockKind = header.keyword.caseInsensitiveCompare("host") == .orderedSame ? .host : .match
            let hostPatterns = kind == .host ? header.values : []
            let owner: UUID?
            if kind == .host, start > lines.startIndex {
                owner = Self.ownedHostID(in: Self.content(of: lines[start - 1]))
            } else {
                owner = nil
            }
            let rangeStart = owner == nil ? start : start - 1
            return Block(
                kind: kind,
                line: start + 1,
                hostPatterns: hostPatterns,
                managedHostID: owner,
                lines: lines[start..<end].map(Self.content),
                range: rangeStart..<end
            )
        }
    }

    private mutating func ensureManagedTail() {
        guard trailingTailStart == nil else { return }
        if let last = lines.last, !Self.content(of: last).isEmpty {
            lines.append(Data("\n".utf8))
        }
        lines.append(contentsOf: Self.managedTail.map { Data("\($0)\n".utf8) })
    }

    private var trailingTailStart: Int? {
        guard lines.count >= Self.managedTail.count,
              Array(lines.map(Self.content).suffix(Self.managedTail.count)) == Self.managedTail
        else {
            return nil
        }
        return lines.endIndex - Self.managedTail.count
    }

    private static let managedTail = ["Host *", "    Include ~/.ssh/config", "    Include /etc/ssh/ssh_config"]

    private static func renderedLines(for host: SSHManagedHost) -> [Data] {
        var result = [
            Data("# chostty-host-id: \(host.hostID.uuidString)\n".utf8),
            Data("Host \(host.alias)\n".utf8),
            Data("    HostName \(host.hostName)\n".utf8),
        ]
        if let user = host.user { result.append(Data("    User \(user)\n".utf8)) }
        if let port = host.port { result.append(Data("    Port \(port)\n".utf8)) }
        for identityFile in host.identityFiles {
            result.append(Data("    IdentityFile \(identityFile)\n".utf8))
        }
        if let proxyJump = host.proxyJump { result.append(Data("    ProxyJump \(proxyJump)\n".utf8)) }
        if let identitiesOnly = host.identitiesOnly {
            result.append(Data("    IdentitiesOnly \(identitiesOnly ? "yes" : "no")\n".utf8))
        }
        if let forwardAgent = host.forwardAgent {
            result.append(Data("    ForwardAgent \(forwardAgent ? "yes" : "no")\n".utf8))
        }
        if let interval = host.serverAliveInterval {
            result.append(Data("    ServerAliveInterval \(interval)\n".utf8))
        }
        result.append(contentsOf: host.otherLines.map { Data("\($0)\n".utf8) })
        return result
    }

    private static func splitLines(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var result: [Data] = []
        var lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            result.append(data[lineStart...index])
            lineStart = data.index(after: index)
        }
        if lineStart < data.endIndex {
            result.append(data[lineStart..<data.endIndex])
        }
        return result
    }

    private static func content(of data: Data) -> String {
        // Invalid UTF-8 stays opaque in the raw document; owned blocks reject it before editing.
        guard var line = String(bytes: data, encoding: .utf8) else { return "�" }
        while line.last == "\n" || line.last == "\r" {
            line.removeLast()
        }
        return line
    }

    private static func ownedHostID(in line: String) -> UUID? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(ownershipPrefix) else { return nil }
        return UUID(uuidString: String(trimmed.dropFirst(ownershipPrefix.count)))
    }

    struct Directive {
        let keyword: String
        let values: [String]
    }

    static func directive(in line: String) -> Directive? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let tokens = tokens(in: trimmed)
        guard let first = tokens.first else { return nil }
        if let equal = first.firstIndex(of: "=") {
            return Directive(
                keyword: String(first[..<equal]),
                values: [String(first[first.index(after: equal)...])] + tokens.dropFirst())
        }
        return Directive(keyword: first, values: Array(tokens.dropFirst()))
    }

    private static func tokens(in line: String) -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                token.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                if !token.isEmpty {
                    result.append(token)
                    token = ""
                }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { result.append(token) }
        return result
    }

    private static func hostPatterns(_ patterns: [String], match alias: String) -> Bool {
        var included = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatches(String(pattern.dropFirst()), value: alias) { return false }
            } else if wildcardMatches(pattern, value: alias) {
                included = true
            }
        }
        return included
    }

    private static func wildcardMatches(_ pattern: String, value: String) -> Bool {
        let pattern = Array(pattern)
        let value = Array(value)
        var patternIndex = 0
        var valueIndex = 0
        var star: Int?
        var restart = 0
        while valueIndex < value.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex] {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                star = patternIndex
                patternIndex += 1
                restart = valueIndex
            } else if let star {
                patternIndex = star + 1
                restart += 1
                valueIndex = restart
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    private static func boolValue(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }

    private static func isValidScalar(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.controlCharacters.contains($0)
        }
    }
}
