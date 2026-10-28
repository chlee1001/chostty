import AppKit
import Darwin
import Foundation

@MainActor
final class SSHPaneChannel {
    let alias: String
    let launchID: UUID
    let autoConnect: Bool
    private(set) var binding: SSHPaneBinding
    private(set) var lastStateSequence = 0
    private let createdAt = Date().timeIntervalSince1970
    private var supervisor: SSHAskpassProcessIdentity?
    private var onDispose: (@Sendable () -> Void)?
    private let directory: URL
    private let controlDescriptor: Int32
    private let watcher: DispatchSourceFileSystemObject
    private var sequence = 0
    private weak var surface: Ghostty.SurfaceView?
    private weak var coordinator: SSHPaneCoordinator?
    private var observedState: SSHPaneStateFile?

    private init?(launch: SSHPaneLaunch, surface: Ghostty.SurfaceView) {
        directory = launch.runtimeDirectory
        alias = launch.binding.reference.alias
        launchID = launch.launchID
        autoConnect = launch.autoConnect
        binding = launch.binding
        self.surface = surface

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }

        let control = directory.appendingPathComponent("control").path
        guard mkfifo(control, 0o600) == 0 || errno == EEXIST else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let controlDescriptor = open(control, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard controlDescriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        self.controlDescriptor = controlDescriptor

        let directoryDescriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            close(controlDescriptor)
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: .write,
            queue: .main)
        watcher.setEventHandler { [weak self] in self?.readState() }
        watcher.setCancelHandler { close(directoryDescriptor) }
        watcher.resume()

        surface.restoreTitle(alias)
        surface.sshStatus = SSHPaneStatus(connection: .waiting, reconnectBlock: nil)
        (NSApp.delegate as? AppDelegate)?.sshServices?.coordinator.register(self)
    }

    static func attach(_ launch: SSHPaneLaunch?, to surface: Ghostty.SurfaceView) -> SSHPaneChannel? {
        guard let launch else { return nil }
        return SSHPaneChannel(launch: launch, surface: surface)
    }

    deinit {
        onDispose?()
        watcher.cancel()
        close(controlDescriptor)
        try? FileManager.default.removeItem(at: directory)
    }

    var commandSequence: Int { sequence }

    func reserveCommandSequence() -> Int {
        sequence += 1
        return sequence
    }

    func shouldCloseAfterProcessExit() -> Bool {
        guard
            let contents = try? String(contentsOf: directory.appendingPathComponent("state"), encoding: .utf8),
            let state = SSHPaneStateFile.parse(contents),
            case let .exited(stateSequence, status, everConnected) = state,
            stateSequence == sequence,
            everConnected,
            status != 255
        else { return false }
        return true
    }

    func sendConnect(sequence: Int, token: String?) {
        send("connect", sequence: sequence, argument: token ?? "-")
    }

    func pinnedSupervisor() -> SSHAskpassProcessIdentity? {
        if let supervisor { return supervisor }
        guard let tty = surface?.surfaceModel?.ttyName,
              let device = SSHAskpassProcess.ttyDevice(named: tty),
              let identity = SSHAskpassProcess.pinSupervisor(
                pidFile: directory.appendingPathComponent("pid"),
                ttyDevice: device,
                channelCreatedAt: createdAt)
        else { return nil }
        supervisor = identity
        return identity
    }

    var canRequestConnect: Bool {
        switch surface?.sshStatus?.connection {
        case .waiting, .lost: return true
        default: return false
        }
    }

    func requestConnect() {
        coordinator?.requestConnect(launchID: launchID)
    }

    func setCoordinator(_ coordinator: SSHPaneCoordinator, onDispose: @escaping @Sendable () -> Void) {
        self.coordinator = coordinator
        self.onDispose = onDispose
    }

    func sendDeny(_ reason: SSHReconnectBlock, sequence: Int) {
        let value: String
        switch reason {
        case .hostRemoved: value = "hostRemoved"
        case .aliasInvalid: value = "aliasInvalid"
        case .configUnreadable: value = "configUnreadable"
        }
        send("deny", sequence: sequence, argument: value)
    }

    func setReconnectBlock(_ block: SSHReconnectBlock?) {
        guard var status = surface?.sshStatus else { return }
        status.reconnectBlock = block
        surface?.sshStatus = status
    }

    func updateDisplayDestination(_ destination: String) {
        binding.displayDestination = destination
        if let status = surface?.sshStatus {
            surface?.sshStatus = status
        }
    }

    private func send(_ command: String, sequence: Int, argument: String? = nil) {
        guard sequence == self.sequence else { return }
        SSHLog.logger.notice(
            "channel.command id=\(self.launchID.uuidString, privacy: .public) command=\(command, privacy: .public) seq=\(sequence, privacy: .public)")
        let suffix = argument.map { " \($0)" } ?? ""
        let line = "\(command) \(sequence)\(suffix)\n"
        line.withCString { pointer in
            var count: Int
            repeat {
                count = write(controlDescriptor, pointer, strlen(pointer))
            } while count < 0 && errno == EINTR
            if count != strlen(pointer) {
                onDispose?()
                surface?.sshStatus = SSHPaneStatus(
                    connection: .lost(exitStatus: 255, everConnected: false),
                    reconnectBlock: surface?.sshStatus?.reconnectBlock)
            }
        }
    }

    private func readState() {
        guard
            let contents = try? String(contentsOf: directory.appendingPathComponent("state"), encoding: .utf8),
            let state = SSHPaneStateFile.parse(contents),
            let surface
        else { return }

        let currentSequence: Int
        switch state {
        case .waiting(let value), .connectRequested(let value), .connecting(let value), .connected(let value):
            currentSequence = value
        case .exited(let value, _, _): currentSequence = value
        }
        guard currentSequence >= lastStateSequence else { return }
        lastStateSequence = currentSequence
        sequence = max(sequence, currentSequence)
        if observedState != state {
            let from = observedState.map { self.stateName($0) } ?? "none"
            let to = stateName(state)
            let result: (rc: String, everConnected: Bool)
            switch state {
            case let .exited(_, status, ever):
                result = (String(status), ever)
            case .waiting, .connectRequested, .connecting, .connected:
                result = ("none", false)
            }
            SSHLog.logger.notice(
                "state.changed id=\(self.launchID.uuidString, privacy: .public) from=\(from, privacy: .public) to=\(to, privacy: .public) seq=\(currentSequence, privacy: .public) rc=\(result.rc, privacy: .public) everConnected=\(result.everConnected, privacy: .public)")
            observedState = state
        }
        let block = surface.sshStatus?.reconnectBlock
        switch state {
        case .waiting:
            surface.sshStatus = SSHPaneStatus(connection: .waiting, reconnectBlock: block)
            coordinator?.supervisorReady(launchID: launchID)
        case .connectRequested:
            requestConnect()
        case .connecting:
            surface.sshStatus = SSHPaneStatus(connection: .connecting, reconnectBlock: block)
        case .connected:
            surface.sshStatus = SSHPaneStatus(connection: .connected, reconnectBlock: block)
            coordinator?.observedConnection(launchID: launchID, sequence: currentSequence)
        case let .exited(_, status, ever):
            surface.sshStatus = SSHPaneStatus(
                connection: .lost(exitStatus: status, everConnected: ever),
                reconnectBlock: block)
            coordinator?.observedConnection(launchID: launchID, sequence: currentSequence)
        }
    }

    private func stateName(_ state: SSHPaneStateFile) -> String {
        switch state {
        case .waiting: "waiting"
        case .connectRequested: "connectRequested"
        case .connecting: "connecting"
        case .connected: "connected"
        case .exited: "exited"
        }
    }
}

/// One line the supervisor writes to the pane state file.
enum SSHPaneStateFile: Equatable, Sendable {
    case waiting(sequence: Int)
    case connectRequested(sequence: Int)
    case connecting(sequence: Int)
    case connected(sequence: Int)
    case exited(sequence: Int, status: Int32, everConnected: Bool)

    static func parse(_ text: String) -> SSHPaneStateFile? {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard let sequenceField = fields.dropFirst().first, let sequence = Int(sequenceField), sequence >= 0 else { return nil }
        switch (fields.first, fields.count) {
        case ("waiting", 2): return .waiting(sequence: sequence)
        case ("connect-requested", 2): return .connectRequested(sequence: sequence)
        case ("connecting", 2): return .connecting(sequence: sequence)
        case ("connected", 2): return .connected(sequence: sequence)
        case ("exited", 4):
            guard let status = Int32(fields[2]), fields[3] == "0" || fields[3] == "1" else { return nil }
            return .exited(sequence: sequence, status: status, everConnected: fields[3] == "1")
        default: return nil
        }
    }
}
