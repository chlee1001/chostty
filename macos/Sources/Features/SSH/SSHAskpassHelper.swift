import Darwin

enum SSHAskpassHelper {
    private static let maximumSecretLength = 1023
    private static let responseMagic: [UInt8] = [0x43, 0x41, 0x50, 0x31]

    /// Called before Ghostty and AppKit initialization. It has no dependency on the application.
    static func run() -> Int32 {
        let parentPID = getppid()
        let mode = getenv("SSH_ASKPASS_PROMPT").map { String(validatingUTF8: $0) ?? "" }
        guard ssh_askpass_native_install_signal_handlers() == 0 else {
            if mode == "none", parentPID > 1 { return runNoticeMode(parentPID) }
            waitForUnknownParent(parentPID)
            return 1
        }
        guard parentPID != 1 else { return 1 }
        if getenv("CHOSTTY_ASKPASS_TUNNEL") != nil { return runTunnel(mode: mode, parentPID: parentPID) }
        if mode == "none" { return runNoticeMode(parentPID) }
        if mode == "confirm" {
            guard let prompt = rawPrompt() else { return 1 }
            return runConfirmation(prompt: prompt, parentPID: parentPID)
        }
        guard let parent = SSHAskpassProcessIdentity.read(parentPID), parent.parentPID > 1,
              parent.realUID == getuid(), parent.effectiveUID == getuid(), parent.ttyDevice != -1
        else {
            waitForUnknownParent(parentPID)
            return 1
        }
        guard let prompt = rawPrompt() else {
            abort(parent)
            return 1
        }
        return runOrdinary(prompt: prompt, mode: mode, parent: parent)
    }

    private static func runOrdinary(prompt: UnsafePointer<CChar>, mode: String?, parent: SSHAskpassProcessIdentity) -> Int32 {
        let parentPID = parent.pid
        guard parentIsCurrent(parent) else { waitForUnknownParent(parentPID); return 1 }
        guard ssh_askpass_native_install_fatal_handlers(parentPID) == 0 else { abort(parent); return 1 }
        defer { ssh_askpass_native_restore_fatal_handlers() }
        if ssh_askpass_native_cancelled() != 0 { abort(parent); return 1 }

        if parent.executablePath.utf8.elementsEqual("/usr/bin/ssh".utf8), mode == nil,
           var promptBytes = utf8Prompt(prompt), let secret = requestBroker(prompt: promptBytes, mode: nil) {
            defer { wipe(&promptBytes) }
            defer { secret.wipe() }
            guard ssh_askpass_native_cancelled() == 0, parentIsCurrent(parent), writeSecret(secret) else {
                abort(parent)
                return 1
            }
            guard ssh_askpass_native_commit_output() != 0 else { return abortAndFail(parent) }
            secret.wipe()
            wipe(&promptBytes)
            ssh_askpass_native_exit_success()
        }

        guard hasTTY() else {
            _ = ssh_askpass_native_wait_for_parent_exit(parentPID, -1)
            return 1
        }
        var answer = [CChar](repeating: 0, count: maximumSecretLength + 2)
        defer {
            answer.withUnsafeMutableBytes { ssh_askpass_native_wipe($0.baseAddress!, $0.count) }
        }
        var length: Int = 0
        let echo: Int32 = echoesAnswer(to: prompt) ? 1 : 0
        let readResult = answer.withUnsafeMutableBufferPointer {
            ssh_askpass_native_read_answer(prompt, $0.baseAddress!, $0.count, &length, parentPID, echo)
        }
        guard readResult == 0,
              ssh_askpass_native_cancelled() == 0,
              parentIsCurrent(parent)
        else {
            abort(parent)
            return 1
        }
        guard (1...maximumSecretLength).contains(length), valid(answer, length: length),
              ssh_askpass_native_cancelled() == 0
        else {
            abort(parent)
            return 1
        }
        let wrote = answer.withUnsafeBytes { writeAll($0.baseAddress!, count: length) }
        guard wrote, ssh_askpass_native_commit_output() != 0 else {
            abort(parent)
            return 1
        }
        wipe(&answer)
        ssh_askpass_native_exit_success()
    }

    /// ssh asks the host-key question without `SSH_ASKPASS_PROMPT`, so only its
    /// text tells it apart from a password. The user should see that answer.
    static func echoesAnswer(to prompt: UnsafePointer<CChar>) -> Bool {
        strstr(prompt, "(yes/no") != nil
    }

    /// A tunnel has no terminal: every prompt goes to the app. Without an answer
    /// the helper writes nothing and ends its ssh, so ssh never receives an
    /// empty password and never waits on a prompt nobody can answer. A notice
    /// gets no answer by design; ssh ends that helper itself.
    private static func runTunnel(mode: String?, parentPID: pid_t) -> Int32 {
        guard let parent = SSHAskpassProcessIdentity.read(parentPID), parent.parentPID > 1,
              parent.realUID == getuid(), parent.effectiveUID == getuid(),
              parent.executablePath.utf8.elementsEqual("/usr/bin/ssh".utf8),
              parentIsCurrent(parent)
        else {
            waitForUnknownParent(parentPID)
            return 1
        }
        // The parent is the verified ssh: a request nobody can answer ends it
        // rather than leaving both processes waiting on each other.
        guard mode == nil || mode == "none" || mode == "confirm",
              let prompt = rawPrompt(), var promptBytes = utf8Prompt(prompt)
        else {
            if mode == "none" {
                waitUntilNoticeEnds(parentPID)
                return 1
            }
            return abortAndFail(parent)
        }
        defer { wipe(&promptBytes) }
        guard ssh_askpass_native_install_fatal_handlers(parentPID) == 0 else { return abortAndFail(parent) }
        defer { ssh_askpass_native_restore_fatal_handlers() }
        guard let secret = requestBroker(prompt: promptBytes, mode: mode) else {
            if mode == "none" {
                waitUntilNoticeEnds(parentPID)
                return 1
            }
            return abortAndFail(parent)
        }
        defer { secret.wipe() }
        guard ssh_askpass_native_cancelled() == 0, parentIsCurrent(parent), writeSecret(secret),
              ssh_askpass_native_commit_output() != 0
        else { return abortAndFail(parent) }
        secret.wipe()
        wipe(&promptBytes)
        ssh_askpass_native_exit_success()
    }

    private static func runConfirmation(prompt: UnsafePointer<CChar>, parentPID: pid_t) -> Int32 {
        guard hasTTY() else {
            _ = ssh_askpass_native_wait_for_parent_exit(parentPID, -1)
            return 1
        }
        var answer = [CChar](repeating: 0, count: maximumSecretLength + 2)
        defer { answer.withUnsafeMutableBytes { ssh_askpass_native_wipe($0.baseAddress!, $0.count) } }
        var count: Int = 0
        let readResult = answer.withUnsafeMutableBufferPointer {
            ssh_askpass_native_read_answer(prompt, $0.baseAddress!, $0.count, &count, parentPID, 1)
        }
        guard readResult == 0, ssh_askpass_native_cancelled() == 0 else { return 1 }
        guard count == 3 else { return 1 }
        let accepted = answer.withUnsafeBufferPointer {
            ($0[0] == 121 || $0[0] == 89) &&
                ($0[1] == 101 || $0[1] == 69) &&
                ($0[2] == 115 || $0[2] == 83)
        }
        guard accepted, ssh_askpass_native_cancelled() == 0 else { return 1 }
        var yes: [UInt8] = [121, 101, 115]
        guard yes.withUnsafeBytes({ writeAll($0.baseAddress!, count: $0.count) }) else { return 1 }
        guard ssh_askpass_native_commit_output() != 0 else { return 1 }
        wipe(&answer)
        wipe(&yes)
        ssh_askpass_native_exit_success()
    }

    private static func runNoticeMode(_ parentPID: pid_t) -> Int32 {
        let descriptor = open("/dev/tty", O_WRONLY | O_NOCTTY | O_CLOEXEC)
        if descriptor >= 0 {
            let text = Array("SSH requires confirmation in its terminal.\n".utf8)
            _ = text.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            _ = Darwin.close(descriptor)
        }
        waitUntilNoticeEnds(parentPID)
        return 1
    }

    /// ssh signals a notice helper once the security key is done, or exits.
    private static func waitUntilNoticeEnds(_ parentPID: pid_t) {
        while ssh_askpass_native_cancelled() == 0 && getppid() == parentPID {
            if ssh_askpass_native_wait_for_parent_exit(parentPID, 250) != 0 { break }
        }
    }

    private static func rawPrompt() -> UnsafePointer<CChar>? {
        guard CommandLine.argc == 2, let argument = CommandLine.unsafeArgv[1] else { return nil }
        return UnsafePointer(argument)
    }

    private static func utf8Prompt(_ prompt: UnsafePointer<CChar>) -> [UInt8]? {
        let count = Int(strlen(prompt))
        guard count <= 4_096 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: prompt, count: count).bindMemory(to: UInt8.self)
        guard String(validatingUTF8: prompt) != nil else { return nil }
        return Array(bytes)
    }

    private static func requestBroker(prompt: [UInt8], mode: String?) -> SSHSecretBuffer? {
        guard let socketText = getenv("CHOSTTY_ASKPASS_SOCKET").flatMap({ String(validatingUTF8: $0) }),
              let tokenText = getenv("CHOSTTY_ASKPASS_TOKEN").flatMap({ String(validatingUTF8: $0) }),
              let address = unixAddress(socketText)
        else { return nil }
        guard var nonce = decodeHex(tokenText) else { return nil }
        defer { wipe(&nonce) }
        guard var request = SSHAskpassBroker.encodeRequest(nonce: nonce, mode: mode, prompt: prompt) else {
            return nil
        }
        defer { wipe(&request) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        guard setCloseOnExec(descriptor), setNoSigPipe(descriptor), setNonBlocking(descriptor),
              let deadline = socketDeadline(seconds: 120), connect(descriptor, address, deadline: deadline),
              brokerUIDMatches(descriptor),
              request.withUnsafeBytes({ writeSocket(descriptor, $0.baseAddress!, count: $0.count, deadline: deadline) }),
              var header = readSocket(descriptor, count: 8, deadline: deadline), header.starts(with: responseMagic),
              header[4] == 1, header[5] == 1
        else { return nil }
        defer { wipe(&header) }
        let length = Int(UInt16(header[6]) << 8 | UInt16(header[7]))
        guard (1...maximumSecretLength).contains(length) else { return nil }
        return try? SSHSecretBuffer(count: length) { buffer in
            guard readSocket(descriptor, into: buffer.baseAddress!, count: length, deadline: deadline),
                  !buffer.contains(0), !buffer.contains(10), !buffer.contains(13)
            else { throw SSHSecretStoreError.invalidSecret }
        }
    }

    private static func abortAndFail(_ parent: SSHAskpassProcessIdentity) -> Int32 { abort(parent); return 1 }

    private static func abort(_ parent: SSHAskpassProcessIdentity) {
        guard parentIsCurrent(parent) else { waitForUnknownParent(parent.pid); return }
        _ = kill(parent.pid, SIGTERM)
        guard ssh_askpass_native_wait_for_parent_exit(parent.pid, 1_000) == 0 else { return }
        guard parentIsCurrent(parent) else {
            waitForUnknownParent(parent.pid)
            return
        }
        _ = kill(parent.pid, SIGKILL)
        _ = ssh_askpass_native_wait_for_parent_exit(parent.pid, -1)
    }

    private static func parentIsCurrent(_ parent: SSHAskpassProcessIdentity) -> Bool {
        guard getppid() == parent.pid,
              let current = SSHAskpassProcessIdentity.read(parent.pid),
              let selfIdentity = SSHAskpassProcessIdentity.read(getpid()),
              current.pid == parent.pid,
              current.realUID == parent.realUID,
              current.effectiveUID == parent.effectiveUID,
              current.startSeconds == parent.startSeconds,
              current.startMicroseconds == parent.startMicroseconds,
              current.ttyDevice == parent.ttyDevice,
              current.executablePath.utf8.elementsEqual(parent.executablePath.utf8)
        else { return false }
        return parent.startedNoLater(than: selfIdentity)
    }

    private static func waitForUnknownParent(_ parentPID: pid_t) {
        guard parentPID > 1 else { return }
        _ = ssh_askpass_native_wait_for_parent_exit(parentPID, -1)
    }

    private static func hasTTY() -> Bool {
        let descriptor = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        return isatty(descriptor) == 1
    }

    private static func valid(_ answer: [CChar], length: Int) -> Bool {
        answer.prefix(length).allSatisfy { $0 != 0 && $0 != 10 && $0 != 13 }
    }

    private static func wipe<T>(_ buffer: inout [T]) {
        buffer.withUnsafeMutableBytes {
            ssh_askpass_native_wipe($0.baseAddress!, $0.count)
        }
    }

    private static func writeSecret(_ secret: SSHSecretBuffer) -> Bool {
        secret.withUnsafeBytes { writeAll($0.baseAddress!, count: $0.count) }
    }

    private static func writeAll(_ pointer: UnsafeRawPointer, count: Int) -> Bool {
        var written = 0
        while written < count {
            if ssh_askpass_native_cancelled() != 0 { return false }
            let result = Darwin.write(STDOUT_FILENO, pointer.advanced(by: written), count - written)
            if result < 0 {
                if errno == EINTR {
                    if ssh_askpass_native_cancelled() != 0 { return false }
                    continue
                }
                return false
            }
            if result == 0 { return false }
            written += result
        }
        return ssh_askpass_native_cancelled() == 0
    }

    private static func unixAddress(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count + 1 <= 104 else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address) { raw in
            bytes.withUnsafeBytes { raw.baseAddress!.advanced(by: 2).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        return address
    }

    private static func connect(_ descriptor: Int32, _ address: sockaddr_un, deadline: UInt64) -> Bool {
        var address = address
        while ssh_askpass_native_cancelled() == 0 {
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            if connected || errno == EISCONN { return true }
            if errno == EINTR { continue }
            guard errno == EINPROGRESS || errno == EALREADY,
                  waitSocket(descriptor, events: Int16(POLLOUT), deadline: deadline)
            else { return false }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
        }
        return false
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func setNoSigPipe(_ descriptor: Int32) -> Bool {
        var value: Int32 = 1
        return setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func brokerUIDMatches(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }

    private static func socketDeadline(seconds: UInt64) -> UInt64? {
        var now = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &now) == 0, now.tv_sec >= 0 else { return nil }
        return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec) + seconds * 1_000_000_000
    }

    private static func waitSocket(_ descriptor: Int32, events: Int16, deadline: UInt64) -> Bool {
        while ssh_askpass_native_cancelled() == 0 {
            var now = timespec()
            guard clock_gettime(CLOCK_MONOTONIC, &now) == 0, now.tv_sec >= 0 else { return false }
            let current = UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
            guard current < deadline else { return false }
            let remaining = deadline - current
            let milliseconds = min((remaining + 999_999) / 1_000_000, UInt64(Int32.max))
            var waiter = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&waiter, 1, Int32(milliseconds))
            if result > 0 {
                if (waiter.revents & events) != 0 { return true }
                if (waiter.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 { return false }
                continue
            }
            if result == 0 { continue }
            if errno != EINTR { return false }
        }
        return false
    }

    private static func readSocket(_ descriptor: Int32, count: Int, deadline: UInt64) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard bytes.withUnsafeMutableBytes({ readSocket(descriptor, into: $0.baseAddress!, count: count, deadline: deadline) }) else { return nil }
        return bytes
    }

    private static func readSocket(
        _ descriptor: Int32,
        into pointer: UnsafeMutableRawPointer,
        count: Int,
        deadline: UInt64
    ) -> Bool {
        var offset = 0
        while offset < count {
            if ssh_askpass_native_cancelled() != 0 { return false }
            let result = Darwin.read(descriptor, pointer.advanced(by: offset), count - offset)
            if result == 0 { return false }
            if result < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitSocket(descriptor, events: Int16(POLLIN), deadline: deadline) else { return false }
                    continue
                }
                return false
            }
            offset += result
        }
        return ssh_askpass_native_cancelled() == 0
    }

    private static func writeSocket(_ descriptor: Int32, _ pointer: UnsafeRawPointer, count: Int, deadline: UInt64) -> Bool {
        var offset = 0
        while offset < count {
            if ssh_askpass_native_cancelled() != 0 { return false }
            let result = Darwin.write(descriptor, pointer.advanced(by: offset), count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitSocket(descriptor, events: Int16(POLLOUT), deadline: deadline) else { return false }
                    continue
                }
                return false
            }
            if result == 0 { return false }
            offset += result
        }
        return ssh_askpass_native_cancelled() == 0
    }

    private static func decodeHex(_ text: String) -> [UInt8]? {
        guard text.utf8.count == 64 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(32)
        var iterator = text.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let a = hex(high), let b = hex(low) else { return nil }
            result.append(a << 4 | b)
        }
        return result.count == 32 ? result : nil
    }

    private static func hex(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 65...70: return value - 55
        case 97...102: return value - 87
        default: return nil
        }
    }
}
