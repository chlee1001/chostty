import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHPaneChannelTests {
    private func makeChannel(
        runtimeDirectory: URL
    ) throws -> (channel: SSHPaneChannel, surface: Ghostty.SurfaceView) {
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let launch = SSHPaneLaunch(
            binding: .init(reference: .init(source: .sshConfig, alias: "prod")),
            launchID: UUID(), runtimeDirectory: runtimeDirectory, autoConnect: false)
        return (try #require(SSHPaneChannel.attach(launch, to: surface)), surface)
    }

    @Test func numberedCommandsQueueAtomicallyBeforeReaderOpens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let launch = SSHPaneLaunch(
            binding: .init(reference: .init(source: .sshConfig, alias: "prod")),
            launchID: UUID(), runtimeDirectory: root, autoConnect: false)
        let channel = try #require(SSHPaneChannel.attach(launch, to: surface))
        let token = String(repeating: "a", count: 64)
        channel.sendConnect(sequence: channel.reserveCommandSequence(), token: token)
        channel.sendDeny(.hostRemoved, sequence: channel.reserveCommandSequence())
        channel.sendConnect(sequence: channel.reserveCommandSequence(), token: nil)
        let reader = open(root.appendingPathComponent("control").path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        #expect(reader >= 0)
        defer { close(reader) }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(reader, &bytes, bytes.count)
        #expect(count > 0)
        let commands = try #require(String(bytes: bytes.prefix(Int(count)), encoding: .utf8))
        #expect(commands == "connect 1 \(token)\ndeny 2 hostRemoved\nconnect 3 -\n")
    }

    @Test func normalCompletedConnectionClosesForAnyNon255Status() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (channel, surface) = try makeChannel(runtimeDirectory: root)
        _ = surface
        #expect(channel.reserveCommandSequence() == 1)

        let state = root.appendingPathComponent("state")
        try "exited 1 0 1\n".write(to: state, atomically: true, encoding: .utf8)
        #expect(channel.shouldCloseAfterProcessExit())

        try "exited 1 42 1\n".write(to: state, atomically: true, encoding: .utf8)
        #expect(channel.shouldCloseAfterProcessExit())
    }

    @Test func failedOrNeverConnectedExitDoesNotClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (channel, surface) = try makeChannel(runtimeDirectory: root)
        _ = surface
        #expect(channel.reserveCommandSequence() == 1)

        let state = root.appendingPathComponent("state")
        try "exited 1 255 1\n".write(to: state, atomically: true, encoding: .utf8)
        #expect(!channel.shouldCloseAfterProcessExit())

        try "exited 1 0 0\n".write(to: state, atomically: true, encoding: .utf8)
        #expect(!channel.shouldCloseAfterProcessExit())
    }

    @Test func closeDecisionFailsClosedForInvalidOrStaleFinalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (channel, surface) = try makeChannel(runtimeDirectory: root)
        _ = surface
        #expect(channel.reserveCommandSequence() == 1)
        #expect(channel.reserveCommandSequence() == 2)

        let state = root.appendingPathComponent("state")
        #expect(!channel.shouldCloseAfterProcessExit())

        try "exited malformed\n".write(to: state, atomically: true, encoding: .utf8)
        #expect(!channel.shouldCloseAfterProcessExit())

        try "exited 1 0 1\n".write(to: state, atomically: true, encoding: .utf8)
        #expect(!channel.shouldCloseAfterProcessExit())
    }

    @Test func closeDecisionRereadsFinalStateWithoutWatcherDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (channel, surface) = try makeChannel(runtimeDirectory: root)
        _ = surface
        #expect(channel.reserveCommandSequence() == 1)

        try "exited 1 0 1\n".write(
            to: root.appendingPathComponent("state"),
            atomically: true,
            encoding: .utf8)
        #expect(channel.shouldCloseAfterProcessExit())
    }
}
