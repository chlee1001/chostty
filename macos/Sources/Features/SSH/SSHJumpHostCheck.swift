import Darwin
import Foundation

/// One hop of a `ProxyJump` value: `[user@]host[:port]`, an `ssh://` URI, or a
/// config alias (a bare host).
struct SSHProxyJumpHop: Equatable, Sendable {
    var user = ""
    var host = ""
    var port = ""

    init(user: String = "", host: String = "", port: String = "") {
        self.user = user
        self.host = host
        self.port = port
    }

    init(parsing value: String) {
        var rest = Substring(value)
        if rest.hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = String(after.dropFirst()) }
        } else if let colon = rest.firstIndex(of: ":"), rest.lastIndex(of: ":") == colon {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
        } else {
            host = String(rest)
        }
    }

    /// The hop in `ProxyJump` syntax; empty when every field is empty.
    var value: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return (user.isEmpty ? "" : "\(user)@") + hostPart + (port.isEmpty ? "" : ":\(port)")
    }

    /// Valid only when the literal round-trips, so `host:`, `@host` or
    /// `[::1]junk` cannot pass through a lossy parse.
    static func isValid(_ literal: String) -> Bool {
        let hop = SSHProxyJumpHop(parsing: literal)
        let bare = literal.hasPrefix("ssh://") ? String(literal.dropFirst(6)) : literal
        guard hop.value == bare, !hop.host.isEmpty, !hop.host.hasPrefix("-"), !hop.user.hasPrefix("-") else {
            return false
        }
        if hop.host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, hop.host, &address) == 1 else { return false }
        }
        return hop.port.isEmpty || Int(hop.port).map { (1...65_535).contains($0) } == true
    }
}

enum SSHProxyJump {
    static func isValid(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        } && value.split(separator: ",", omittingEmptySubsequences: false).allSatisfy {
            SSHProxyJumpHop.isValid(String($0))
        }
    }

    /// Check Jump Host signs in to one hop only: OpenSSH starts earlier hops
    /// itself, without the options that keep the check from prompting.
    static func isSingleHop(_ value: String) -> Bool {
        isValid(value) && !value.contains(",")
    }
}

enum SSHJumpHostCheckResult: Equatable, Sendable {
    case signedIn(String)
    /// `passwordOffered` records whether the server listed a password method.
    case authenticationRefused(String, passwordOffered: Bool)
    case hostKeyUnknown(String)
    case hostKeyChanged(String)
    case unreachable(String, reason: String)
    case failed(String, reason: String)
    case unresolved

    var succeeded: Bool {
        if case .signedIn = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .signedIn(let label):
            return "Signed in to \(label)."
        case .authenticationRefused(let label, passwordOffered: true):
            return "Reached \(label), but it refused key authentication. Its password is asked for in the terminal when you connect."
        case .authenticationRefused(let label, passwordOffered: false):
            return "Reached \(label), but it refused key authentication. Check the jump host's User and IdentityFile."
        case .hostKeyUnknown(let label):
            return "Reached \(label), but its host key is not in known_hosts yet. Connect once to review and trust it."
        case .hostKeyChanged(let label):
            return "\(label) presented a host key that differs from known_hosts. Check it before connecting."
        case .unreachable(let label, let reason):
            return "Could not reach \(label): \(reason)"
        case .failed(let label, let reason):
            return "Check of \(label) failed: \(reason)"
        case .unresolved:
            return "ssh could not resolve this jump host."
        }
    }
}

protocol SSHJumpHostChecking: Sendable {
    /// `allowMatchExec` must be true when the configuration contains `Match
    /// exec`; the user has to consent before ssh evaluates it.
    func check(
        proxyJump: String,
        configFile: URL?,
        containsMatchExec: Bool,
        allowMatchExec: Bool,
        completion: @escaping @Sendable (SSHJumpHostCheckResult) -> Void)
}

/// Signs in to a single jump host with `BatchMode` and strict host key
/// checking, so the check never prompts, never records a host key, never
/// reuses a multiplexed session and never sends a password.
final class SSHJumpHostChecker: SSHJumpHostChecking, @unchecked Sendable {
    private let sshURL: URL
    private let environment: [String: String]
    private let loginEnvironment: SSHLoginEnvironmentProvider?
    private let timeout: TimeInterval

    /// `loginEnvironment` supplies the login-shell `PATH` and `SSH_AUTH_SOCK`
    /// that panes and tunnels use, so a ProxyCommand on that `PATH` or an agent
    /// set in a login profile works the same way in the check.
    init(
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginEnvironment: SSHLoginEnvironmentProvider? = nil,
        timeout: TimeInterval = 20
    ) {
        self.sshURL = sshURL
        self.environment = environment
        self.loginEnvironment = loginEnvironment
        self.timeout = timeout
    }

    /// The environment for the check's ssh: no askpass or display, so nothing
    /// can prompt, and the login `PATH` and agent socket when known.
    static func environment(base: [String: String], login: SSHLoginEnvironment?) -> [String: String] {
        var environment = base.filter { key, _ in
            !key.hasPrefix("SSH_ASKPASS") && key != "DISPLAY"
                && !key.hasPrefix("CHOSTTY_SSH") && !key.hasPrefix("CHOSTTY_ASKPASS")
        }
        if let login {
            environment["PATH"] = login.path
            environment["SSH_AUTH_SOCK"] = login.authSocket
        }
        return environment
    }

    func check(
        proxyJump: String,
        configFile: URL?,
        containsMatchExec: Bool,
        allowMatchExec: Bool,
        completion: @escaping @Sendable (SSHJumpHostCheckResult) -> Void
    ) {
        guard !containsMatchExec || allowMatchExec,
              let arguments = Self.arguments(proxyJump: proxyJump, configFile: configFile)
        else {
            completion(.unresolved)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let environment = Self.environment(base: self.environment, login: self.loginEnvironment?.load())
            guard let resolved = Self.run(
                executable: self.sshURL, arguments: ["-G"] + arguments.options + arguments.destination,
                environment: environment, timeout: self.timeout),
                resolved.exited, resolved.status == 0,
                let destination = SSHResolver.parse(data: resolved.output)?.destination
            else {
                completion(.unresolved)
                return
            }
            let label = (destination.user.map { "\($0)@" } ?? "") + "\(destination.hostName):\(destination.port)"
            let result = Self.run(
                executable: self.sshURL, arguments: arguments.options + arguments.destination + ["true"],
                environment: environment, timeout: self.timeout)
            completion(Self.classify(
                status: result.map { $0.exited ? $0.status : nil } ?? nil,
                timedOut: result == nil,
                errorOutput: result?.errorOutput ?? Data(),
                label: label))
        }
    }

    struct Arguments: Equatable {
        let options: [String]
        let destination: [String]
    }

    static let hardening = [
        "-T",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UpdateHostKeys=no",
        "-o", "ConnectTimeout=8",
        "-o", "ConnectionAttempts=1",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
        "-o", "ClearAllForwardings=yes",
        "-o", "PermitLocalCommand=no",
        "-o", "ForkAfterAuthentication=no",
        "-o", "RemoteCommand=none",
        "-o", "SessionType=default",
    ]

    static func arguments(proxyJump: String, configFile: URL?) -> Arguments? {
        guard SSHProxyJump.isSingleHop(proxyJump) else { return nil }
        let options = (configFile.map { ["-F", $0.path] } ?? []) + hardening
        return Arguments(options: options, destination: ["--", destination(for: proxyJump)])
    }

    /// A bare alias stays an alias so its config block applies; anything with a
    /// user or port becomes an `ssh://` URI, the only destination form with a port.
    static func destination(for value: String) -> String {
        let hop = SSHProxyJumpHop(parsing: value)
        guard !hop.user.isEmpty || !hop.port.isEmpty || value.hasPrefix("ssh://") else { return hop.host }
        return "ssh://" + hop.value
    }

    /// `status` is nil when ssh did not exit normally (a signal, or the timeout).
    static func classify(status: Int32?, timedOut: Bool = false, errorOutput: Data, label: String) -> SSHJumpHostCheckResult {
        if timedOut { return .unreachable(label, reason: "timed out.") }
        guard let status else { return .failed(label, reason: "ssh was stopped.") }
        // ssh reserves 255 for its own errors; any other status came from the remote command.
        guard status == 255 else { return .signedIn(label) }
        let lines = (String(bytes: errorOutput, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged(label) }
        if text.contains("Host key verification failed") { return .hostKeyUnknown(label) }
        if let denied = lines.last(where: { $0.contains("Permission denied") }) {
            let offersPassword = denied.contains("password") || denied.contains("keyboard-interactive")
            return .authenticationRefused(label, passwordOffered: offersPassword)
        }
        if text.contains("Too many authentication failures") {
            return .authenticationRefused(label, passwordOffered: false)
        }
        // Sessions refused after login, as on bastions that only forward.
        if text.contains("open failed") { return .signedIn(label) }
        let reason = lines.last ?? "ssh exited with status \(status)."
        let unreachable = [
            "Could not resolve hostname", "Connection refused", "timed out", "No route to host",
            "Network is unreachable", "Connection closed", "Connection reset", "kex_exchange_identification",
        ]
        if unreachable.contains(where: text.contains) { return .unreachable(label, reason: reason) }
        return .failed(label, reason: reason)
    }

    private struct Output {
        let exited: Bool
        let status: Int32
        let output: Data
        let errorOutput: Data
    }

    private static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Output? {
        let output = Pipe()
        let errorOutput = Pipe()
        let descriptors = [
            output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor,
            errorOutput.fileHandleForReading.fileDescriptor, errorOutput.fileHandleForWriting.fileDescriptor,
        ]
        guard descriptors.allSatisfy(setCloseOnExec),
              setNonBlocking(descriptors[0]), setNonBlocking(descriptors[2])
        else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput
        guard (try? process.run()) != nil else { return nil }
        output.fileHandleForWriting.closeFile()
        errorOutput.fileHandleForWriting.closeFile()
        defer {
            output.fileHandleForReading.closeFile()
            errorOutput.fileHandleForReading.closeFile()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var outputData = Data()
        var errorData = Data()
        while true {
            drain(descriptors[0], into: &outputData)
            drain(descriptors[2], into: &errorData)
            if !process.isRunning {
                process.waitUntilExit()
                drain(descriptors[0], into: &outputData)
                drain(descriptors[2], into: &errorData)
                return Output(
                    exited: process.terminationReason == .exit,
                    status: process.terminationStatus,
                    output: outputData,
                    errorOutput: errorData)
            }
            if Date() >= deadline {
                process.terminate()
                return nil
            }
            usleep(20_000)
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

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }
}
