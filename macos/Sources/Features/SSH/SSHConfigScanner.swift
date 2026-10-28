import Darwin
import Foundation

struct SSHFileStat: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case directory
        case other
    }

    let kind: Kind
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

enum SSHConfigDiagnostic: Equatable, Sendable {
    case missing(URL)
    case permissionDenied(URL)
    case includeCycle(URL)
    case depthExceeded(URL)
    case unsupportedAlias(String, URL, Int)
    case duplicateAlias(String, URL, Int)

    var message: String {
        func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
        switch self {
        case .missing(let url): return "\(display(url)) doesn't exist."
        case .permissionDenied(let url): return "Chostty can't read \(display(url))."
        case .includeCycle(let url): return "\(display(url)) is included in a loop and was skipped."
        case .depthExceeded(let url): return "\(display(url)) is nested too deeply in Include and was skipped."
        case .unsupportedAlias(let alias, let url, let line):
            return "Host \(alias) in \(display(url)):\(line) can't be used as a Chostty alias."
        case .duplicateAlias(let alias, let url, let line):
            return "Host \(alias) in \(display(url)):\(line) is already defined earlier and is ignored."
        }
    }
}

enum SSHFileObservation: Equatable, Sendable {
    case file(device: UInt64, inode: UInt64, size: UInt64, modificationSeconds: Int64, modificationNanoseconds: Int64)
    case directory(device: UInt64, inode: UInt64, modificationSeconds: Int64, modificationNanoseconds: Int64)
    case missing
    case unreadable(Int32)
}

protocol SSHFileSystem: Sendable {
    func contents(of url: URL) throws -> String
    func metadata(of url: URL) throws -> SSHFileStat
    func glob(_ pattern: String) throws -> [URL]
    func realpath(_ url: URL) -> URL?
}

struct LocalSSHFileSystem: SSHFileSystem {
    func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func metadata(of url: URL) throws -> SSHFileStat {
        var value = Darwin.stat()
        guard stat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind: SSHFileStat.Kind
        switch value.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        default: kind = .other
        }
        return SSHFileStat(
            kind: kind,
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: UInt64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    func glob(_ pattern: String) throws -> [URL] {
        var value = Darwin.glob_t()
        defer { Darwin.globfree(&value) }
        let result = Darwin.glob(pattern, 0, nil, &value)
        guard result == 0 || result == GLOB_NOMATCH else {
            throw POSIXError(POSIXErrorCode(rawValue: Int32(result)) ?? .EIO)
        }
        guard result == 0, let paths = value.gl_pathv else { return [] }
        return (0..<Int(value.gl_pathc)).compactMap { index in
            paths[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }.sorted { $0.path < $1.path }
    }

    func realpath(_ url: URL) -> URL? {
        guard let path = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
}

struct SSHConfigScanResult: Equatable, Sendable {
    var entries: [SSHHostEntry]
    var diagnostics: [SSHConfigDiagnostic]
    var containsMatchExec: Bool
    var observations: [String: SSHFileObservation]
}

enum SSHConfigScanner {
    static func scan(root: URL, paths: SSHPaths, fileSystem: any SSHFileSystem = LocalSSHFileSystem()) -> SSHConfigScanResult {
        var scanner = Scanner(paths: paths, fileSystem: fileSystem, includeBase: includeBase(for: root, paths: paths))
        scanner.read(root, depth: 0, inMatch: false)
        return SSHConfigScanResult(
            entries: scanner.entries,
            diagnostics: scanner.diagnostics,
            containsMatchExec: scanner.containsMatchExec,
            observations: scanner.observations
        )
    }

    static func observationsAreCurrent(
        _ observations: [String: SSHFileObservation],
        fileSystem: any SSHFileSystem = LocalSSHFileSystem()
    ) -> Bool {
        observations.allSatisfy { path, observation in
            observation == observe(URL(fileURLWithPath: path), fileSystem: fileSystem)
        }
    }

    private static func includeBase(for root: URL, paths: SSHPaths) -> URL {
        if root.standardizedFileURL == paths.systemConfig.standardizedFileURL {
            return paths.systemConfig.deletingLastPathComponent()
        }
        return paths.userConfig.deletingLastPathComponent()
    }

    private static func observe(_ url: URL, fileSystem: any SSHFileSystem) -> SSHFileObservation {
        do {
            let stat = try fileSystem.metadata(of: url)
            switch stat.kind {
            case .directory:
                return .directory(
                    device: stat.device,
                    inode: stat.inode,
                    modificationSeconds: stat.modificationSeconds,
                    modificationNanoseconds: stat.modificationNanoseconds
                )
            case .file, .other:
                return .file(
                    device: stat.device,
                    inode: stat.inode,
                    size: stat.size,
                    modificationSeconds: stat.modificationSeconds,
                    modificationNanoseconds: stat.modificationNanoseconds
                )
            }
        } catch {
            let code = errorCode(error)
            return code == ENOENT || code == ENOTDIR ? .missing : .unreadable(code)
        }
    }

    private static func errorCode(_ error: Error) -> Int32 {
        if let error = error as? POSIXError { return Int32(error.errorCode) }
        return Int32(truncatingIfNeeded: (error as NSError).code)
    }

    private struct Scanner {
        let paths: SSHPaths
        let fileSystem: any SSHFileSystem
        let includeBase: URL
        var entries: [SSHHostEntry] = []
        var diagnostics: [SSHConfigDiagnostic] = []
        var observations: [String: SSHFileObservation] = [:]
        var activePaths: Set<String> = []
        var aliases: Set<String> = []
        var containsMatchExec = false

        mutating func read(_ originalURL: URL, depth: Int, inMatch: Bool) {
            guard depth <= 16 else {
                diagnostics.append(.depthExceeded(originalURL))
                return
            }

            let observation = recordObservation(originalURL)
            guard case .file = observation else {
                appendReadDiagnostic(for: originalURL, observation: observation)
                return
            }

            let identity = fileSystem.realpath(originalURL) ?? originalURL.standardizedFileURL
            let key = identity.path
            guard activePaths.insert(key).inserted else {
                diagnostics.append(.includeCycle(originalURL))
                return
            }
            defer { activePaths.remove(key) }

            let contents: String
            do {
                contents = try fileSystem.contents(of: originalURL)
            } catch {
                let unreadable = SSHFileObservation.unreadable(SSHConfigScanner.errorCode(error))
                observations[originalURL.path] = unreadable
                diagnostics.append(.permissionDenied(originalURL))
                return
            }

            var match = inMatch
            for (index, rawLine) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                guard let directive = SSHConfigDocument.directive(in: String(rawLine)) else { continue }
                let values = directive.values
                switch directive.keyword.lowercased() {
                case "match":
                    match = true
                    if values.contains(where: isExecCondition) { containsMatchExec = true }
                case "host" where !match:
                    addAliases(values, definedIn: originalURL, line: index + 1)
                case "include":
                    for value in values {
                        for include in includeURLs(value) {
                            read(include, depth: depth + 1, inMatch: match)
                        }
                    }
                default:
                    break
                }
            }
        }

        mutating func addAliases(_ values: [String], definedIn: URL, line: Int) {
            let concrete = values.filter { !isPattern($0) }
            var valid: [String] = []
            for alias in concrete {
                switch SSHAlias.validate(alias) {
                case .success(let alias): valid.append(alias)
                case .failure: diagnostics.append(.unsupportedAlias(alias, definedIn, line))
                }
            }
            for alias in valid {
                guard aliases.insert(alias).inserted else {
                    diagnostics.append(.duplicateAlias(alias, definedIn, line))
                    continue
                }
                entries.append(SSHHostEntry(
                    reference: SSHHostReference(source: .sshConfig, alias: alias),
                    definedIn: definedIn,
                    line: line,
                    siblingAliases: valid,
                    displayName: nil,
                    isFavorite: false,
                    resolved: nil
                ))
            }
        }

        mutating func includeURLs(_ value: String) -> [URL] {
            let path = expandedPath(value)
            guard containsGlob(path) else { return [URL(fileURLWithPath: path)] }
            observeGlobParents(path)
            return (try? fileSystem.glob(path)) ?? []
        }

        func expandedPath(_ value: String) -> String {
            let expanded: String
            if value == "~" || value.hasPrefix("~/") {
                expanded = paths.home.path + String(value.dropFirst())
            } else {
                expanded = value
            }
            if expanded.hasPrefix("/") { return expanded }
            return includeBase.appendingPathComponent(expanded).path
        }

        mutating func observeGlobParents(_ pattern: String) {
            let components = URL(fileURLWithPath: pattern).pathComponents
            var prefixes = [URL(fileURLWithPath: "/")]
            for component in components.dropFirst() {
                if containsGlob(component) {
                    for prefix in prefixes { _ = recordObservation(prefix) }
                    prefixes = prefixes.flatMap { prefix in
                        (try? fileSystem.glob(prefix.appendingPathComponent(component).path)) ?? []
                    }
                } else {
                    prefixes = prefixes.map { $0.appendingPathComponent(component) }
                }
            }
        }

        mutating func recordObservation(_ url: URL) -> SSHFileObservation {
            let observation = SSHConfigScanner.observe(url, fileSystem: fileSystem)
            observations[url.path] = observation
            return observation
        }

        mutating func appendReadDiagnostic(for url: URL, observation: SSHFileObservation) {
            switch observation {
            case .missing: diagnostics.append(.missing(url))
            case .unreadable: diagnostics.append(.permissionDenied(url))
            case .file, .directory: break
            }
        }

        func isExecCondition(_ value: String) -> Bool {
            let value = value.lowercased()
            return value == "exec" || value == "!exec" || value.hasPrefix("exec=") || value.hasPrefix("!exec=")
        }

        func isPattern(_ alias: String) -> Bool {
            alias.hasPrefix("!") || alias.contains("*") || alias.contains("?") || alias.contains(",")
        }

        func containsGlob(_ value: String) -> Bool {
            value.contains("*") || value.contains("?") || value.contains("[")
        }
    }
}
