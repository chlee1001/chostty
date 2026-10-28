import Foundation
import Testing
@testable import Ghostty

struct SSHPathsTests {
    @Test func usesInjectedXDGConfigHomeWhenNonempty() throws {
        try withTemporarySSHPaths { root in
            let configHome = root.appendingPathComponent("xdg", isDirectory: true)
            let paths = makePaths(root: root, environment: ["XDG_CONFIG_HOME": configHome.path])

            #expect(paths.dataDirectory == configHome.appendingPathComponent("chostty/ssh", isDirectory: true))
            #expect(!paths.dataDirectory.pathComponents.contains("ghostty"))
        }
    }

    @Test func emptyXDGConfigHomeUsesHomeConfigDirectory() throws {
        try withTemporarySSHPaths { root in
            let paths = makePaths(root: root, environment: ["XDG_CONFIG_HOME": ""])

            #expect(paths.dataDirectory == root.appendingPathComponent(".config/chostty/ssh", isDirectory: true))
            #expect(!paths.dataDirectory.pathComponents.contains("ghostty"))
        }
    }

    @Test func exposesManagedHostAndMetadataFilenames() throws {
        try withTemporarySSHPaths { root in
            let paths = makePaths(root: root, environment: [:])

            #expect(paths.managedHostsFile == paths.dataDirectory.appendingPathComponent("hosts.conf"))
            #expect(paths.metadataFile == paths.dataDirectory.appendingPathComponent("hosts.meta.json"))
        }
    }

    #if DEBUG
    @Test func debugDataDirectoryOverrideWinsOverXDGConfigHome() throws {
        try withTemporarySSHPaths { root in
            let override = root.appendingPathComponent("ssh-data", isDirectory: true)
            let paths = makePaths(
                root: root,
                environment: [
                    "CHOSTTY_SSH_DATA_DIR": override.path,
                    "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
                ]
            )

            #expect(paths.dataDirectory == override)
        }
    }
    #endif
}

private func withTemporarySSHPaths(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body(root)
}

private func makePaths(root: URL, environment: [String: String]) -> SSHPaths {
    SSHPaths(
        home: root,
        systemConfig: root.appendingPathComponent("system-config"),
        runtimeRoot: root.appendingPathComponent("runtime"),
        environment: environment
    )
}
