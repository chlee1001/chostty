import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHConfigScannerTests {
    @Test func parsesConcreteAliasesAndDirectives() throws {
        try withTemporarySSHDirectory { _, paths in
            let config = paths.userConfig
            try """
            hOsT=prod "build" deploy
            Host *.internal !excluded comma,pattern
            mAtCh !eXeC true
            Host ignored
            """.write(to: config, atomically: true, encoding: .utf8)

            let result = SSHConfigScanner.scan(root: config, paths: paths)
            #expect(result.entries.map(\.reference.alias) == ["prod", "build", "deploy"])
            #expect(result.entries.map(\.line) == [1, 1, 1])
            #expect(result.containsMatchExec)
        }
    }

    @Test func followsIncludesFromSSHRootAndRecordsDefinitions() throws {
        try withTemporarySSHDirectory { root, paths in
            let snippets = root.appendingPathComponent(".ssh/snippets", isDirectory: true)
            try FileManager.default.createDirectory(at: snippets, withIntermediateDirectories: true)
            let include = snippets.appendingPathComponent("one.conf")
            try "Host included second\n".write(to: include, atomically: true, encoding: .utf8)
            try "Include snippets/*.conf\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)

            let result = SSHConfigScanner.scan(root: paths.userConfig, paths: paths)
            #expect(result.entries.map(\.reference.alias) == ["included", "second"])
            #expect(result.entries.allSatisfy { $0.definedIn == include && $0.line == 1 })
            #expect(result.observations[snippets.path] != nil)
            #expect(result.observations[include.path] != nil)
        }
    }

    @Test func resolvesSystemRelativeIncludesFromSystemConfigurationDirectory() throws {
        try withTemporarySSHDirectory { root, paths in
            let etc = root.appendingPathComponent("etc", isDirectory: true)
            try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
            let included = etc.appendingPathComponent("system.conf")
            try "Host system\n".write(to: included, atomically: true, encoding: .utf8)
            try "Include system.conf\n".write(to: paths.systemConfig, atomically: true, encoding: .utf8)

            let result = SSHConfigScanner.scan(root: paths.systemConfig, paths: paths)
            #expect(result.entries.first?.definedIn == included)
        }
    }

    @Test func expandsHomeAndBlocksIncludeCyclesAndDepth() throws {
        try withTemporarySSHDirectory { root, paths in
            let cycle = root.appendingPathComponent(".ssh/cycle")
            try "Include cycle\n".write(to: cycle, atomically: true, encoding: .utf8)
            try "Include ~/.ssh/cycle\nHost root\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)

            let result = SSHConfigScanner.scan(root: paths.userConfig, paths: paths)
            #expect(result.entries.map(\.reference.alias) == ["root"])
            #expect(result.diagnostics.contains(.includeCycle(cycle)))

            let cycleLink = root.appendingPathComponent(".ssh/cycle-link")
            try FileManager.default.createSymbolicLink(at: cycleLink, withDestinationURL: cycle)
            try "Include cycle-link\n".write(to: cycle, atomically: true, encoding: .utf8)
            let linkCycleResult = SSHConfigScanner.scan(root: paths.userConfig, paths: paths)
            #expect(linkCycleResult.diagnostics.contains(.includeCycle(cycleLink)))

            for index in 0...16 {
                let file = root.appendingPathComponent(".ssh/depth\(index)")
                let text = index == 16 ? "Host too-deep\n" : "Include depth\(index + 1)\n"
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            try "Include depth0\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let depthResult = SSHConfigScanner.scan(root: paths.userConfig, paths: paths)
            #expect(depthResult.diagnostics.contains(.depthExceeded(root.appendingPathComponent(".ssh/depth16"))))
            #expect(!depthResult.entries.contains { $0.reference.alias == "too-deep" })
        }
    }

    @Test func recordsInvalidAndDuplicateAliasesAndMissingFiles() throws {
        try withTemporarySSHDirectory { root, paths in
            try "Host good bad%alias\nHost good\nInclude absent\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let result = SSHConfigScanner.scan(root: paths.userConfig, paths: paths)
            #expect(result.entries.map(\.reference.alias) == ["good"])
            #expect(result.diagnostics.contains(.unsupportedAlias("bad%alias", paths.userConfig, 1)))
            #expect(result.diagnostics.contains(.duplicateAlias("good", paths.userConfig, 2)))
            #expect(result.diagnostics.contains(.missing(root.appendingPathComponent(".ssh/absent"))))
            // Every diagnostic names its file, and alias problems name the host and line.
            let messages = result.diagnostics.map(\.message)
            #expect(messages.contains { $0.hasPrefix("Host bad%alias in ") && $0.contains("config:1 ") })
            #expect(messages.contains { $0.hasPrefix("Host good in ") && $0.contains("config:2 ") })
            #expect(messages.contains { $0.hasSuffix("absent doesn't exist.") })
        }
    }

    @Test func recordsPermissionDeniedFromInjectedFileSystem() throws {
        try withTemporarySSHDirectory { _, paths in
            try "Host unavailable\n".write(to: paths.userConfig, atomically: true, encoding: .utf8)
            let result = SSHConfigScanner.scan(
                root: paths.userConfig,
                paths: paths,
                fileSystem: DenyingSSHFileSystem(deniedURL: paths.userConfig)
            )
            #expect(result.diagnostics.contains(.permissionDenied(paths.userConfig)))
            #expect(result.observations[paths.userConfig.path] == .unreadable(EACCES))
            #expect(result.entries.isEmpty)
        }
    }
}

private func withTemporarySSHDirectory(_ body: (URL, SSHPaths) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ssh = root.appendingPathComponent(".ssh", isDirectory: true)
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    let paths = SSHPaths(
        home: root,
        userConfig: ssh.appendingPathComponent("config"),
        systemConfig: root.appendingPathComponent("etc/ssh_config"),
        runtimeRoot: root.appendingPathComponent("runtime")
    )
    try body(root, paths)
}

private struct DenyingSSHFileSystem: SSHFileSystem {
    let deniedURL: URL
    private let local = LocalSSHFileSystem()

    func contents(of url: URL) throws -> String {
        if url == deniedURL { throw POSIXError(.EACCES) }
        return try local.contents(of: url)
    }

    func metadata(of url: URL) throws -> SSHFileStat {
        try local.metadata(of: url)
    }

    func glob(_ pattern: String) throws -> [URL] {
        try local.glob(pattern)
    }

    func realpath(_ url: URL) -> URL? {
        local.realpath(url)
    }
}
