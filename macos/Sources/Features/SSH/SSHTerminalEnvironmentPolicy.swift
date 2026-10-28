import Foundation
import GhosttyKit

enum SSHEnvOutcome: Equatable, Sendable {
    case forcedOn
    case userOn
    case explicitOff
    case mismatchFollowConfig
    case undeterminedFollowConfig
}

struct SSHEnvProvenance: Equatable, Sendable {
    var assignment: String?
    var isUndetermined: Bool
    var scanned: Ghostty.Config.ShellIntegrationFeatures
    var undeterminedReason: String?
    var filesRead: Int

    init(
        assignment: String?,
        isUndetermined: Bool,
        scanned: Ghostty.Config.ShellIntegrationFeatures? = nil,
        undeterminedReason: String? = nil,
        filesRead: Int = 0
    ) {
        self.assignment = assignment
        self.isUndetermined = isUndetermined
        self.scanned = scanned ?? SSHTerminalEnvironmentPolicy.parsePackedStruct(assignment)
            ?? SSHTerminalEnvironmentPolicy.defaultFeatures
        self.undeterminedReason = undeterminedReason
        self.filesRead = filesRead
    }
}

struct SSHTerminalEnvironment: Equatable, Sendable {
    let forwardEnv: Bool
    let terminfo: Bool
    let outcome: SSHEnvOutcome
}

enum SSHTerminalEnvironmentPolicy {
    static let defaultFeatures = Ghostty.Config.ShellIntegrationFeatures.defaults

    static func currentProvenance(
        themeDirectories: [(url: URL, isUser: Bool)] = ThemeCatalog.directories()
    ) -> SSHEnvProvenance {
        collect(
            configPath: nil,
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments,
            isRunningInXcode: isRunningInXcode(),
            themeDirectories: themeDirectories
        )
    }

    static func collect(
        configPath: URL?,
        environment: [String: String],
        arguments: [String],
        isRunningInXcode: Bool,
        themeDirectories: [(url: URL, isUser: Bool)],
        fileSystem: any SSHFileSystem = LocalSSHFileSystem()
    ) -> SSHEnvProvenance {
        let cliIsUndetermined = !isRunningInXcode && arguments.contains {
            $0 == "--config-file"
                || $0.hasPrefix("--config-file=")
                || $0 == "--config-default-files"
                || $0.hasPrefix("--config-default-files=")
        }
        if cliIsUndetermined {
            return SSHEnvProvenance(
                assignment: nil,
                isUndetermined: true,
                undeterminedReason: "cliConfigSelection")
        }

        // Only Debug builds load GHOSTTY_CONFIG_PATH (AppDelegate), so only they read it here.
#if DEBUG
        let environmentPath = environment["GHOSTTY_CONFIG_PATH"].flatMap { $0.isEmpty ? nil : $0 }
#else
        let environmentPath: String? = nil
#endif
        let rootPaths: [URL]
        if let configPath {
            rootPaths = [configPath]
        } else if let configuredPath = environmentPath {
            rootPaths = [URL(fileURLWithPath: configuredPath)]
        } else {
            let configHome = ConfigHome.directory(environment: environment)
            let appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
            rootPaths = [
                configHome.appendingPathComponent("ghostty/config"),
                configHome.appendingPathComponent("ghostty/config.ghostty"),
                appSupport.appendingPathComponent("config"),
                appSupport.appendingPathComponent("config.ghostty"),
            ]
        }

        var roots: [(document: ConfigDocument, path: String)] = []
        var rootUndecodable = false
        var loadedPaths: Set<String> = []
        var filesRead = 0
        for path in rootPaths {
            let normalized = path.standardizedFileURL.path
            guard loadedPaths.insert(normalized).inserted else { continue }
            do {
                let contents = try fileSystem.contents(of: path)
                filesRead += 1
                roots.append((ConfigDocument(text: contents), normalized))
            } catch {
                if !ConfigLayers.isMissingOrUnreadable(error) {
                    rootUndecodable = true
                }
            }
        }

        if !isRunningInXcode {
            let cli = cliDocument(arguments)
            if !cli.lines.isEmpty {
                roots.append((cli, "/__ghostty_cli__"))
            }
        }

        func layers(prefersDark: Bool) -> ConfigLayers {
            ConfigLayers(
                roots: roots,
                prefersDark: prefersDark,
                themeDirectories: themeDirectories,
                readFile: {
                    let contents = try fileSystem.contents(of: URL(fileURLWithPath: $0))
                    filesRead += 1
                    return contents
                },
                fileExists: { (try? fileSystem.metadata(of: $0)) != nil }
            )
        }

        let light = layers(prefersDark: false)
        let dark = layers(prefersDark: true)
        let lightProvenance = provenance(from: light)
        let darkProvenance = provenance(from: dark)
        let pairedThemeDisagrees = light.themeValue.flatMap(ThemeCatalog.Selection.init)?.isPair == true
            && policyIntent(lightProvenance.assignment) != policyIntent(darkProvenance.assignment)
        let isUndetermined = rootUndecodable
            || light.hasEmptyConfigFile
            || light.hasUndecodableInclude
            || light.themeLoadFailed
            || dark.themeLoadFailed
            || pairedThemeDisagrees
        let undeterminedReason: String?
        if rootUndecodable {
            undeterminedReason = "rootUnreadable"
        } else if light.hasEmptyConfigFile {
            undeterminedReason = "emptyConfigFile"
        } else if light.hasUndecodableInclude {
            undeterminedReason = "includeUndecodable"
        } else if light.themeLoadFailed || dark.themeLoadFailed {
            undeterminedReason = "themeLoadFailed"
        } else if pairedThemeDisagrees {
            undeterminedReason = "pairedThemeMismatch"
        } else {
            undeterminedReason = nil
        }
        return SSHEnvProvenance(
            assignment: lightProvenance.assignment,
            isUndetermined: isUndetermined,
            scanned: lightProvenance.scanned,
            undeterminedReason: undeterminedReason,
            filesRead: filesRead
        )
    }

    static func decide(
        actual: Ghostty.Config.ShellIntegrationFeatures,
        provenance: SSHEnvProvenance
    ) -> SSHTerminalEnvironment {
        let terminfo = actual.contains(.sshTerminfo)
        let environment: SSHTerminalEnvironment
        if actual.contains(.sshEnv) {
            environment = SSHTerminalEnvironment(forwardEnv: true, terminfo: terminfo, outcome: .userOn)
        } else if provenance.isUndetermined {
            environment = SSHTerminalEnvironment(
                forwardEnv: false,
                terminfo: terminfo,
                outcome: .undeterminedFollowConfig
            )
        } else if provenance.scanned != actual {
            environment = SSHTerminalEnvironment(
                forwardEnv: false,
                terminfo: terminfo,
                outcome: .mismatchFollowConfig
            )
        } else if policyIntent(provenance.assignment) == .off {
            environment = SSHTerminalEnvironment(
                forwardEnv: false,
                terminfo: terminfo,
                outcome: .explicitOff)
        } else {
            environment = SSHTerminalEnvironment(forwardEnv: true, terminfo: terminfo, outcome: .forcedOn)
        }
        let outcome: String
        switch environment.outcome {
        case .forcedOn: outcome = "forced-on"
        case .userOn: outcome = "user-on"
        case .explicitOff: outcome = "explicit-off"
        case .mismatchFollowConfig: outcome = "mismatch-follow-config"
        case .undeterminedFollowConfig: outcome = "undetermined-follow-config"
        }
        let reason = environment.outcome == .undeterminedFollowConfig
            ? provenance.undeterminedReason ?? "unspecified"
            : "none"
        SSHLog.logger.notice(
            "ssh-env.policy outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) filesRead=\(provenance.filesRead, privacy: .public)")
        return environment
    }

    private enum PolicyIntent: Equatable {
        case forced
        case on
        case off
    }

    private static func provenance(from layers: ConfigLayers) -> SSHEnvProvenance {
        var assignment: String?
        var scanned = defaultFeatures
        let documents = ([layers.theme?.document].compactMap { $0 }
            + layers.roots.map(\.document)
            + layers.includes.map(\.document))
        for value in documents.flatMap({ $0.values(forKey: "shell-integration-features") }) {
            if let parsed = parsePackedStruct(value) {
                assignment = value
                scanned = parsed
            }
        }
        return SSHEnvProvenance(assignment: assignment, isUndetermined: false, scanned: scanned)
    }

    private static func cliDocument(_ arguments: [String]) -> ConfigDocument {
        var entries: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            for key in ["shell-integration-features", "theme"] {
                let prefix = "--\(key)="
                if argument.hasPrefix(prefix) {
                    entries.append("\(key) = \(argument.dropFirst(prefix.count))")
                    break
                }
                if argument == "--\(key)", index + 1 < arguments.count {
                    index += 1
                    entries.append("\(key) = \(arguments[index])")
                    break
                }
            }
            index += 1
        }
        return ConfigDocument(text: entries.joined(separator: "\n"))
    }

    private static func policyIntent(_ assignment: String?) -> PolicyIntent {
        guard let assignment else { return .forced }
        let trimmed = assignment.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTrue(trimmed) { return .on }
        if isFalse(trimmed) { return .off }
        let tokens = trimmed.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if tokens.contains("no-ssh-env") { return .off }
        if tokens.contains("ssh-env") { return .on }
        return .forced
    }

    static func parsePackedStruct(_ assignment: String?) -> Ghostty.Config.ShellIntegrationFeatures? {
        guard let assignment else { return nil }
        let value = assignment.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return defaultFeatures }
        if isTrue(value) {
            return [.cursor, .sudo, .title, .sshEnv, .sshTerminfo, .path]
        }
        if isFalse(value) { return [] }

        var result = defaultFeatures
        for rawToken in value.split(separator: ",", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled: Bool
            let name: String
            if token.hasPrefix("no-") {
                enabled = false
                name = String(token.dropFirst(3))
            } else {
                enabled = true
                name = token
            }
            let feature: Ghostty.Config.ShellIntegrationFeatures
            switch name {
            case "cursor": feature = .cursor
            case "sudo": feature = .sudo
            case "title": feature = .title
            case "ssh-env": feature = .sshEnv
            case "ssh-terminfo": feature = .sshTerminfo
            case "path": feature = .path
            default: return nil
            }
            if enabled {
                result.insert(feature)
            } else {
                result.remove(feature)
            }
        }
        return result
    }

    private static func isTrue(_ value: String) -> Bool {
        ["1", "t", "T", "true"].contains(value)
    }

    private static func isFalse(_ value: String) -> Bool {
        ["0", "f", "F", "false"].contains(value)
    }
}
