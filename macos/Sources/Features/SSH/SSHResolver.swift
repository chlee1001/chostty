import Darwin
import Foundation

protocol SSHResolving: Sendable {
    func resolve(
        reference: SSHHostReference,
        paths: SSHPaths,
        observations: [String: SSHFileObservation],
        containsMatchExec: Bool,
        reason: SSHResolver.Reason,
        completion: @escaping @Sendable (SSHResolver.Result?) -> Void
    )

    func resolveBaseline(
        alias: String,
        completion: @escaping @Sendable (SSHResolver.Result?) -> Void
    )
}

final class SSHResolver: SSHResolving, @unchecked Sendable {
    /// Why `ssh -G` runs; each case is one allowed call site. Only an explicit
    /// request the user confirmed may run a config graph with `Match exec`.
    enum Reason: Equatable, Sendable {
        case connect
        case explicit(allowMatchExec: Bool)
        case duplicate(allowMatchExec: Bool)

        var allowsMatchExec: Bool {
            switch self {
            case .connect: return false
            case .explicit(let allowed), .duplicate(let allowed): return allowed
            }
        }

        var name: String {
            switch self {
            case .connect: return "connect"
            case .explicit: return "explicit"
            case .duplicate: return "duplicate"
            }
        }
    }

    struct Result: Equatable, Sendable {
        let destination: SSHResolvedDestination
        let options: [String: [String]]
    }

    private struct CacheEntry {
        let reference: SSHHostReference
        let configurationPath: URL?
        let observations: [String: SSHFileObservation]
        let allowedMatchExec: Bool
        let result: Result?
    }

    private let sshURL: URL
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cache: [CacheEntry] = []

    init(
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) {
        self.sshURL = sshURL
        self.environment = environment
        self.timeout = timeout
    }

    func resolve(
        reference: SSHHostReference,
        paths: SSHPaths,
        observations: [String: SSHFileObservation],
        containsMatchExec: Bool,
        reason: Reason,
        completion: @escaping @Sendable (Result?) -> Void
    ) {
        let allowMatchExec = reason.allowsMatchExec
        guard case .success = SSHAlias.validate(reference.alias),
              !containsMatchExec || allowMatchExec
        else {
            completion(nil)
            return
        }

        let configurationPath: URL?
        let arguments: [String]
        switch reference.source {
        case .managed:
            configurationPath = paths.managedHostsFile
            arguments = ["-G", "-F", paths.managedHostsFile.path, "--", reference.alias]
        case .sshConfig:
            configurationPath = paths.userConfig
            arguments = ["-G", "--", reference.alias]
        }

        lock.lock()
        if let cached = cache.first(where: {
            $0.reference == reference &&
                $0.configurationPath == configurationPath &&
                $0.observations == observations &&
                $0.allowedMatchExec == allowMatchExec
        }) {
            lock.unlock()
            completion(cached.result)
            return
        }
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let result = Self.run(
                executable: self.sshURL,
                arguments: arguments,
                environment: self.environment,
                timeout: self.timeout,
                reason: reason
            ).flatMap(Self.parse)
            self.lock.lock()
            self.cache.removeAll {
                $0.reference == reference &&
                    $0.configurationPath == configurationPath &&
                    $0.allowedMatchExec == allowMatchExec
            }
            self.cache.append(CacheEntry(
                reference: reference,
                configurationPath: configurationPath,
                observations: observations,
                allowedMatchExec: allowMatchExec,
                result: result))
            self.lock.unlock()
            completion(result)
        }
    }

    func resolveBaseline(
        alias: String,
        completion: @escaping @Sendable (Result?) -> Void
    ) {
        guard case .success = SSHAlias.validate(alias) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            completion(Self.run(
                executable: self.sshURL,
                arguments: ["-G", "-F", "/dev/null", "--", alias],
                environment: self.environment,
                timeout: self.timeout,
                reason: .duplicate(allowMatchExec: false)
            ).flatMap(Self.parse))
        }
    }

    static func parse(data: Data) -> Result? {
        guard let output = String(bytes: data, encoding: .utf8) else { return nil }
        var options: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            options[String(fields[0]).lowercased(), default: []].append(String(fields[1]))
        }

        let user = options["user"]?.last
        guard let hostName = options["hostname"]?.last, isSafeDestinationComponent(hostName),
              let portValue = options["port"]?.last,
              let port = Int(portValue), (1...65_535).contains(port),
              user.map(isSafeDestinationComponent) ?? true
        else {
            return nil
        }
        return Result(
            destination: SSHResolvedDestination(
                user: user,
                hostName: hostName,
                port: port),
            options: options)
    }

    private static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        reason: Reason
    ) -> Data? {
        let startedAt = Date()
        var timedOut = false
        defer {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            SSHLog.logger.notice(
                "resolver.ran reason=\(reason.name, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) timedOut=\(timedOut, privacy: .public)")
        }
        let output = Pipe()
        let readDescriptor = output.fileHandleForReading.fileDescriptor
        let writeDescriptor = output.fileHandleForWriting.fileDescriptor
        guard setCloseOnExec(readDescriptor), setCloseOnExec(writeDescriptor) else { return nil }
        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags >= 0, fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        output.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while true {
            drain(readDescriptor, into: &data)
            if !process.isRunning {
                drain(readDescriptor, into: &data)
                output.fileHandleForReading.closeFile()
                return process.terminationStatus == 0 ? data : nil
            }
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                output.fileHandleForReading.closeFile()
                return nil
            }
            usleep(10_000)
        }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func isSafeDestinationComponent(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.controlCharacters.contains($0)
        }
    }
}
