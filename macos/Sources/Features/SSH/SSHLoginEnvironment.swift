import Darwin
import Foundation

struct SSHLoginEnvironment: Equatable, Sendable {
    let path: String
    let authSocket: String?
}

final class SSHLoginEnvironmentProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: SSHLoginEnvironment?
    private let shellURL: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval

    init(
        shellURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 3
    ) {
        self.shellURL = shellURL
        self.environment = environment
        self.timeout = timeout
    }

    func value(completion: @escaping @Sendable (SSHLoginEnvironment) -> Void) {
        lock.lock()
        if let cached {
            lock.unlock()
            completion(cached)
            return
        }
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            completion(self.load())
        }
    }

    func load() -> SSHLoginEnvironment {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = discover()
        cached = value
        return value
    }

    private func discover() -> SSHLoginEnvironment {
        let fallback = SSHLoginEnvironment(
            path: environment["PATH"] ?? "/usr/bin:/bin",
            authSocket: environment["SSH_AUTH_SOCK"])
        guard let shellURL = shellURL ?? Self.loginShell() else { return fallback }
        let script = "printf '\\036chostty-begin\\037%s\\037%s\\036chostty-end\\n' \"$PATH\" \"${SSH_AUTH_SOCK-}\""
        guard let data = Self.run(
            executable: shellURL,
            arguments: ["-l", "-c", script],
            environment: environment,
            timeout: timeout
        ) else { return fallback }
        return Self.parse(data: data) ?? fallback
    }

    static func parse(data: Data) -> SSHLoginEnvironment? {
        let startMarker = Data("\u{1E}chostty-begin\u{1F}".utf8)
        let endMarker = Data("\u{1E}chostty-end".utf8)
        guard
            let start = data.range(of: startMarker),
            let end = data.range(of: endMarker, in: start.upperBound..<data.endIndex),
            let payload = String(bytes: data[start.upperBound..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let values = payload.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard values.count == 2, !values[0].isEmpty else { return nil }
        let socket = String(values[1]).trimmingCharacters(in: .newlines)
        return SSHLoginEnvironment(path: String(values[0]), authSocket: socket.isEmpty ? nil : socket)
    }

    private static func loginShell() -> URL? {
        guard let account = getpwuid(getuid()), let shell = account.pointee.pw_shell else { return nil }
        return URL(fileURLWithPath: String(cString: shell))
    }

    private static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Data? {
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
        while process.isRunning {
            drain(readDescriptor, into: &data)
            if Date() >= deadline {
                process.terminate()
                output.fileHandleForReading.closeFile()
                return nil
            }
            usleep(10_000)
        }
        drain(readDescriptor, into: &data)
        output.fileHandleForReading.closeFile()
        return process.terminationStatus == 0 ? data : nil
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
}

private func setCloseOnExec(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFD)
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
}
