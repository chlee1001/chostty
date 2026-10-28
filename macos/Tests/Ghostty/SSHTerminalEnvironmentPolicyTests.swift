import Foundation
import Testing
@testable import Ghostty

private struct SSHEnvTestFileSystem: SSHFileSystem {
    enum Failure: Sendable {
        case missing
        case permissionDenied
        case undecodable
    }

    let files: [String: String]
    let failures: [String: Failure]

    func contents(of url: URL) throws -> String {
        if let text = files[url.path] { return text }
        switch failures[url.path] ?? .missing {
        case .missing:
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        case .permissionDenied:
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)
        case .undecodable:
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadInapplicableStringEncoding.rawValue)
        }
    }

    func metadata(of url: URL) throws -> SSHFileStat {
        if let failure = failures[url.path] {
            if case .missing = failure { throw CocoaError(.fileNoSuchFile) }
        } else if files[url.path] == nil {
            throw CocoaError(.fileNoSuchFile)
        }
        return SSHFileStat(
            kind: .file, device: 1, inode: 1,
            size: UInt64(files[url.path]?.utf8.count ?? 0),
            modificationSeconds: 0, modificationNanoseconds: 0
        )
    }

    func glob(_ pattern: String) throws -> [URL] {
        files.keys.filter { $0 == pattern }.map { URL(fileURLWithPath: $0) }
    }
    func realpath(_ url: URL) -> URL? { url }
}

struct SSHTerminalEnvironmentPolicyTests {
    private let actual: Ghostty.Config.ShellIntegrationFeatures = [.cursor, .title, .path]

    private func collect(
        _ config: String,
        files: [String: String] = [:],
        failures: [String: SSHEnvTestFileSystem.Failure] = [:],
        arguments: [String] = ["Ghostty"],
        isRunningInXcode: Bool = false,
        themes: [(url: URL, isUser: Bool)] = []
    ) -> SSHEnvProvenance {
        let root = URL(fileURLWithPath: "/fixture/config")
        var allFiles = files
        allFiles[root.path] = config
        return SSHTerminalEnvironmentPolicy.collect(
            configPath: root,
            environment: [:],
            arguments: arguments,
            isRunningInXcode: isRunningInXcode,
            themeDirectories: themes,
            fileSystem: SSHEnvTestFileSystem(files: allFiles, failures: failures)
        )
    }

    @Test("decide follows the fail-closed table")
    func decideTable() {
        let defaultResult = SSHTerminalEnvironmentPolicy.decide(actual: actual, provenance: SSHEnvProvenance(assignment: nil, isUndetermined: false))
        #expect(defaultResult == .init(forwardEnv: true, terminfo: false, outcome: .forcedOn))

        let userOn = SSHTerminalEnvironmentPolicy.decide(
            actual: actual.union(.sshEnv),
            provenance: SSHEnvProvenance(assignment: "ssh-env", isUndetermined: false)
        )
        #expect(userOn == .init(forwardEnv: true, terminfo: false, outcome: .userOn))

        let explicitOff = SSHTerminalEnvironmentPolicy.decide(
            actual: actual,
            provenance: SSHEnvProvenance(assignment: "no-ssh-env", isUndetermined: false)
        )
        #expect(explicitOff == .init(forwardEnv: false, terminfo: false, outcome: .explicitOff))

        let mismatch = SSHTerminalEnvironmentPolicy.decide(
            actual: actual,
            provenance: SSHEnvProvenance(assignment: "ssh-env", isUndetermined: false)
        )
        #expect(mismatch == .init(forwardEnv: false, terminfo: false, outcome: .mismatchFollowConfig))

        let undetermined = SSHTerminalEnvironmentPolicy.decide(
            actual: actual.union(.sshTerminfo),
            provenance: SSHEnvProvenance(assignment: nil, isUndetermined: true)
        )
        #expect(undetermined == .init(forwardEnv: false, terminfo: true, outcome: .undeterminedFollowConfig))
    }

    @Test("roots share one breadth-first include queue")
    func breadthFirstCounterexample() {
        let rootA = URL(fileURLWithPath: "/fixture/ghostty/config")
        let rootC = URL(fileURLWithPath: "/fixture/ghostty/config.ghostty")
        let fileB = URL(fileURLWithPath: "/fixture/ghostty/b")
        let fileSystem = SSHEnvTestFileSystem(files: [
            rootA.path: "config-file = b\nshell-integration-features = no-ssh-env\n",
            rootC.path: "shell-integration-features = ssh-env\n",
            fileB.path: "shell-integration-features = no-ssh-env\n",
        ], failures: [:])
        let provenance = SSHTerminalEnvironmentPolicy.collect(
            configPath: nil,
            environment: ["XDG_CONFIG_HOME": "/fixture"],
            arguments: ["Ghostty"],
            isRunningInXcode: false,
            themeDirectories: [],
            fileSystem: fileSystem
        )
        // A/C/B means the include is after every root.
        #expect(provenance.assignment == "no-ssh-env")
    }

    @Test("theme is first and a root overrides it")
    func themePrecedence() {
        let themeDirectory = URL(fileURLWithPath: "/themes")
        let provenance = collect(
            "theme = Night\nshell-integration-features = ssh-env\n",
            files: ["/themes/Night": "shell-integration-features = no-ssh-env\n"],
            themes: [(themeDirectory, true)]
        )
        #expect(provenance.assignment == "ssh-env")
        #expect(!provenance.isUndetermined)
    }

    @Test("theme pair disagreement is undetermined")
    func themePairDisagreement() {
        let themeDirectory = URL(fileURLWithPath: "/themes")
        let provenance = collect(
            "theme = light:Day,dark:Night\n",
            files: [
                "/themes/Day": "shell-integration-features = ssh-env\n",
                "/themes/Night": "shell-integration-features = no-ssh-env\n",
            ],
            themes: [(themeDirectory, true)]
        )
        #expect(provenance.isUndetermined)
    }

    @Test("missing theme is undetermined")
    func missingTheme() {
        #expect(collect("theme = Missing\n").isUndetermined)
    }

    @Test("app support roots participate in default order")
    func appSupportRoot() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")
        let provenance = SSHTerminalEnvironmentPolicy.collect(
            configPath: nil,
            environment: ["XDG_CONFIG_HOME": "/empty"],
            arguments: ["Ghostty"],
            isRunningInXcode: false,
            themeDirectories: [],
            fileSystem: SSHEnvTestFileSystem(files: [
                appSupport.path: "shell-integration-features = no-ssh-env\n",
            ], failures: [:])
        )
        #expect(provenance.assignment == "no-ssh-env")
    }

    @Test("CLI values are after roots and excluded in Xcode")
    func cliAndXcode() {
        let arguments = ["Ghostty", "--shell-integration-features=ssh-env"]
        #expect(collect("shell-integration-features = no-ssh-env\n", arguments: arguments).assignment == "ssh-env")
        #expect(collect(
            "shell-integration-features = no-ssh-env\n",
            arguments: arguments,
            isRunningInXcode: true
        ).assignment == "no-ssh-env")
    }

    @Test("config file CLI controls are undetermined outside Xcode")
    func configFileCLIIsUndetermined() {
        #expect(collect("", arguments: ["Ghostty", "--config-file=/tmp/a"]).isUndetermined)
        #expect(collect("", arguments: ["Ghostty", "--config-default-files=false"]).isUndetermined)
        #expect(!collect("", arguments: ["Ghostty", "--config-file=/tmp/a"], isRunningInXcode: true).isUndetermined)
    }

    @Test("missing files on the real file system keep the forced default")
    func missingFilesOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-ssh-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let absentRoot = SSHTerminalEnvironmentPolicy.collect(
            configPath: directory.appendingPathComponent("config"),
            environment: [:],
            arguments: ["Ghostty"],
            isRunningInXcode: false,
            themeDirectories: [],
            fileSystem: LocalSSHFileSystem()
        )
        #expect(!absentRoot.isUndetermined)
        #expect(SSHTerminalEnvironmentPolicy.decide(actual: actual, provenance: absentRoot)
            == .init(forwardEnv: true, terminfo: false, outcome: .forcedOn))

        let root = directory.appendingPathComponent("config.ghostty")
        try "config-file = absent\n".write(to: root, atomically: true, encoding: .utf8)
        let absentInclude = SSHTerminalEnvironmentPolicy.collect(
            configPath: root,
            environment: [:],
            arguments: ["Ghostty"],
            isRunningInXcode: false,
            themeDirectories: [],
            fileSystem: LocalSSHFileSystem()
        )
        #expect(!absentInclude.isUndetermined)
        #expect(absentInclude.assignment == nil)
    }

    @Test("empty include, undecodable input, and config path are handled")
    func undeterminableInputsAndConfigPath() {
        #expect(collect("config-file = \n").isUndetermined)
        #expect(collect(
            "config-file = broken\n",
            failures: ["/fixture/broken": .undecodable]
        ).isUndetermined)
        #expect(collect(
            "config-file = absent\n",
            failures: ["/fixture/absent": .missing]
        ).isUndetermined == false)

        let undecodable = collect(
            "config-file = broken\n",
            failures: ["/fixture/broken": .undecodable]
        )
        #expect(undecodable.undeterminedReason == "includeUndecodable")
        #expect(SSHTerminalEnvironmentPolicy.decide(actual: actual, provenance: undecodable)
            == .init(forwardEnv: false, terminfo: false, outcome: .undeterminedFollowConfig))

        let configured = URL(fileURLWithPath: "/custom/config")
        let provenance = SSHTerminalEnvironmentPolicy.collect(
            configPath: configured,
            environment: ["GHOSTTY_CONFIG_PATH": "/ignored"],
            arguments: ["Ghostty"],
            isRunningInXcode: false,
            themeDirectories: [],
            fileSystem: SSHEnvTestFileSystem(files: [
                configured.path: "shell-integration-features = no-ssh-env\n",
            ], failures: [:])
        )
        #expect(provenance.assignment == "no-ssh-env")

        let environmentPath = URL(fileURLWithPath: "/environment/config")
        let environmentProvenance = SSHTerminalEnvironmentPolicy.collect(
            configPath: nil,
            environment: ["GHOSTTY_CONFIG_PATH": environmentPath.path],
            arguments: ["Ghostty"],
            isRunningInXcode: false,
            themeDirectories: [],
            fileSystem: SSHEnvTestFileSystem(files: [
                environmentPath.path: "shell-integration-features = ssh-env\n",
            ], failures: [:])
        )
        #expect(environmentProvenance.assignment == "ssh-env")
    }
}
