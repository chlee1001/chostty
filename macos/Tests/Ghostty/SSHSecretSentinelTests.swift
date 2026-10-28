import Foundation
import OSLog
import Testing
@testable import Ghostty

@MainActor
struct SSHSecretSentinelTests {
    @Test func launchCommandSurfaceEnvironmentAndSnapshotContainNoSecretSentinel() throws {
        let sentinel = "CHOSTTY-SSH-SECRET-SENTINEL"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = SSHPaneBinding(
            reference: SSHHostReference(source: .sshConfig, alias: "prod"),
            displayDestination: nil)
        var configuration = SSHLaunch.surfaceConfiguration(
            for: binding,
            autoConnect: true,
            environment: SSHLaunchEnvironment(
                executableURL: URL(fileURLWithPath: "/tmp/chostty"),
                supervisorURL: URL(fileURLWithPath: "/tmp/chostty-ssh-supervisor.sh"),
                login: SSHLoginEnvironment(path: "/usr/bin:/bin", authSocket: nil),
                terminal: SSHTerminalEnvironment(forwardEnv: true, terminfo: false, outcome: .forcedOn),
                paths: SSHPaths(home: root, runtimeRoot: root)))

        #expect(!(configuration.command ?? "").contains(sentinel))
        #expect(!configuration.environmentVariables.values.contains { $0.contains(sentinel) })

        // A transient surface value must not become persisted SSH metadata.
        configuration.environmentVariables["CHOSTTY_TEST_TRANSIENT_SECRET"] = sentinel
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: configuration, spawnsSurface: false)
        let snapshot = SessionSnapshotProjection.leaf(from: surface)
        let encoded = try JSONEncoder().encode(snapshot)
        let snapshotJSON = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!snapshotJSON.contains(sentinel))
    }

    /// A saved password and a relayed answer pass through the broker's
    /// authority and reach no log entry, file, or token in this process.
    @Test func servedSecretsReachNoLogFileOrToken() throws {
        let saved = "CHOSTTY-SSH-SAVED-SENTINEL"
        let relayed = "CHOSTTY-SSH-RELAYED-SENTINEL"
        let start = Date()
        let fixture = try SSHTunnelAskpassAuthorizationTests.Fixture()
        defer { fixture.remove() }
        fixture.store.secret = saved
        let authorization = fixture.authorization()
        _ = fixture.observe(authorization) { _, reply in
            reply(SSHTunnelAskpassAuthorizationTests.Fixture.buffer(relayed))
        }
        let (_, token) = try fixture.launch(authorization, managed: true)
        let authority = authorization.tunnelAuthority
        let password = authority.answer(fixture.request(token: token, prompt: fixture.passwordPrompt), fixture.ssh)
        #expect(password.map(SSHTunnelAskpassAuthorizationTests.Fixture.string) == saved)
        let code = authority.answer(fixture.request(token: token, prompt: "Verification code: "), fixture.ssh)
        #expect(code.map(SSHTunnelAskpassAuthorizationTests.Fixture.string) == relayed)
        #expect(!token.contains(saved) && !token.contains(relayed))

        var files = 0
        let enumerator = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            files += 1
            for secret in [saved, relayed, token] {
                #expect(data.range(of: Data(secret.utf8)) == nil, "\(secret) in \(url.lastPathComponent)")
            }
        }
        #expect(files >= 2)

        // Control: the store must see this process's SSH categories at all.
        let marker = "sentinel.sweep \(UUID().uuidString)"
        SSHLog.askpass.notice("\(marker, privacy: .public)")
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.category.hasPrefix("ssh") }
        #expect(entries.contains { $0.composedMessage == marker })
        for entry in entries {
            for secret in [saved, relayed, token] {
                #expect(!entry.composedMessage.contains(secret))
            }
        }
    }
}
