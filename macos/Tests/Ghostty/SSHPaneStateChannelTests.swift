import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHPaneStateChannelTests {
    @MainActor
    @Test func independentChannelsReceiveAtomicStateReplacementsAndCleanUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try #require(TerminalControllerTestHarness.sharedApp.app)
        let first = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let second = Ghostty.SurfaceView(app, baseConfig: nil, spawnsSurface: false)
        let directories = [root.appendingPathComponent("first"), root.appendingPathComponent("second")]
        func launch(_ directory: URL) -> SSHPaneLaunch {
            SSHPaneLaunch(
                binding: SSHPaneBinding(reference: .init(source: .sshConfig, alias: "prod")),
                launchID: UUID(), runtimeDirectory: directory, autoConnect: true)
        }
        var channels = [
            try #require(SSHPaneChannel.attach(launch(directories[0]), to: first)),
            try #require(SSHPaneChannel.attach(launch(directories[1]), to: second))
        ]
        #expect(channels.count == 2)
        // The coordinator sends connect once the supervisor reports waiting;
        // SSHPaneCoordinatorTests cover that. Here each pane has its own FIFO.
        for directory in directories {
            var info = stat()
            #expect(stat(directory.appendingPathComponent("control").path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFIFO)
            #expect(info.st_mode & 0o777 == 0o600)
            let temporary = directory.appendingPathComponent("state.tmp")
            try "connected 1\n".write(to: temporary, atomically: false, encoding: .utf8)
            try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent("state"))
        }
        for _ in 0..<200 {
            if first.sshStatus?.connection == .connected && second.sshStatus?.connection == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.sshStatus?.connection == .connected)
        #expect(second.sshStatus?.connection == .connected)
        channels.removeAll()
        #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func stateParserRejectsIncompleteAndInvalidValues() {
        #expect(SSHPaneStateFile.parse("waiting 0\n") == .waiting(sequence: 0))
        #expect(SSHPaneStateFile.parse("exited 4 255 0\n") == .exited(sequence: 4, status: 255, everConnected: false))
        #expect(SSHPaneStateFile.parse("") == nil)
        #expect(SSHPaneStateFile.parse("connected -1") == nil)
        #expect(SSHPaneStateFile.parse("exited 1 0 2") == nil)
        #expect(SSHPaneStateFile.parse("other 1") == nil)
    }

    @Test func fifoIsPrivateAndRetainsPrewrittenConnectForLateReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let control = directory.appendingPathComponent("control").path
        #expect(mkfifo(control, 0o600) == 0)
        let writer = open(control, O_RDWR | O_CLOEXEC)
        defer { close(writer) }
        #expect(writer >= 0)
        #expect(fcntl(writer, F_GETFD) & FD_CLOEXEC != 0)
        #expect("connect 1\n".withCString { write(writer, $0, strlen($0)) } == 10)

        let reader = open(control, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        defer { close(reader) }
        var bytes = [CChar](repeating: 0, count: 32)
        let count = read(reader, &bytes, bytes.count)
        #expect(String(cString: bytes) == "connect 1\n")
        #expect(count == 10)
        let permissions = try FileManager.default.attributesOfItem(atPath: control)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}
