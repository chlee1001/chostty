import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHLoginEnvironmentTests {
    @Test func ignoresUndecodableNoiseOutsideMarkedValues() {
        let framed = Data("\u{1E}chostty-begin\u{1F}/fake/bin\u{1F}/tmp/agent\u{1E}chostty-end".utf8)
        #expect(SSHLoginEnvironmentProvider.parse(data: Data([0xFF]) + framed + Data([0xFF])) ==
            SSHLoginEnvironment(path: "/fake/bin", authSocket: "/tmp/agent"))
    }

    @Test func rejectsUndecodableMarkedEnvironmentValues() {
        let prefix = Data("\u{1E}chostty-begin\u{1F}/fake/bin\u{1F}/tmp/agent".utf8)
        let output = prefix + Data([0xFF]) + Data("\u{1E}chostty-end".utf8)
        #expect(SSHLoginEnvironmentProvider.parse(data: output) == nil)
    }

    @Test func readsOnlyMarkedLoginEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shell = directory.appendingPathComponent("shell")
        try "#!/bin/sh\nprintf 'noise\\n\\036chostty-begin\\037/fake/bin\\037/tmp/agent\\036chostty-end\\n'\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        #expect(chmod(shell.path, 0o700) == 0)

        let provider = SSHLoginEnvironmentProvider(
            shellURL: shell,
            environment: ["PATH": "/fallback"],
            timeout: 1)
        #expect(provider.load() == SSHLoginEnvironment(path: "/fake/bin", authSocket: "/tmp/agent"))
    }

    @Test func returnsFallbackAtDeadlineWithoutEOF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shell = directory.appendingPathComponent("shell")
        try "#!/bin/sh\n/bin/sleep 30 &\n/bin/sleep 30\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        #expect(chmod(shell.path, 0o700) == 0)

        let provider = SSHLoginEnvironmentProvider(
            shellURL: shell,
            environment: ["PATH": "/fallback", "SSH_AUTH_SOCK": "/fallback-agent"],
            timeout: 0.05)
        let started = Date()
        #expect(provider.load() == SSHLoginEnvironment(path: "/fallback", authSocket: "/fallback-agent"))
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
