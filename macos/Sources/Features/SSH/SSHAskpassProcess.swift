import Darwin
import Foundation

struct SSHAskpassProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let realUID: uid_t
    let effectiveUID: uid_t
    let startSeconds: Int64
    let startMicroseconds: Int64
    let ttyDevice: dev_t
    let executablePath: String

    static func read(_ pid: pid_t) -> Self? {
        guard pid > 1, let info = SSHRuntimeRoot.processInfo(for: pid), info.pbi_pid == UInt32(pid) else {
            return nil
        }
        // PROC_PIDPATHINFO_MAXSIZE's compound C macro is not imported into Swift.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0,
              let end = path.firstIndex(of: 0),
              let executablePath = String(bytes: path[..<end], encoding: .utf8),
              executablePath.hasPrefix("/"),
              let verifiedInfo = SSHRuntimeRoot.processInfo(for: pid),
              sameKernelProcess(info, verifiedInfo)
        else { return nil }
        return Self(
            pid: pid,
            parentPID: pid_t(info.pbi_ppid),
            realUID: info.pbi_ruid,
            effectiveUID: info.pbi_uid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec),
            ttyDevice: dev_t(bitPattern: info.e_tdev),
            executablePath: executablePath)
    }

    static func sameKernelProcess(_ first: proc_bsdinfo, _ second: proc_bsdinfo) -> Bool {
        first.pbi_pid == second.pbi_pid && first.pbi_ppid == second.pbi_ppid &&
            first.pbi_ruid == second.pbi_ruid && first.pbi_uid == second.pbi_uid &&
            first.e_tdev == second.e_tdev && first.pbi_start_tvsec == second.pbi_start_tvsec &&
            first.pbi_start_tvusec == second.pbi_start_tvusec
    }

    func startedNoLater(than other: Self) -> Bool {
        (startSeconds, startMicroseconds) <= (other.startSeconds, other.startMicroseconds)
    }

    /// The same kernel process, even after an exec changed its path (the
    /// macOS `/bin/sh` trampoline execs the real shell).
    func isSameProcess(as other: Self) -> Bool {
        pid == other.pid && parentPID == other.parentPID && realUID == other.realUID &&
            effectiveUID == other.effectiveUID && startSeconds == other.startSeconds &&
            startMicroseconds == other.startMicroseconds
    }
}

enum SSHAskpassProcess {
    typealias Inspector = (pid_t) -> SSHAskpassProcessIdentity?

    static func ttyDevice(named name: String) -> dev_t? {
        guard name.hasPrefix("/dev/"), !name.utf8.contains(0) else { return nil }
        var info = stat()
        guard lstat(name, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
        return info.st_rdev
    }

    // Pin once against the live surface, never against a request-supplied tty or PID.
    static func pinSupervisor(
        pidFile: URL,
        ttyDevice: dev_t,
        channelCreatedAt: TimeInterval,
        uid: uid_t = getuid(),
        inspect: Inspector = SSHAskpassProcessIdentity.read
    ) -> SSHAskpassProcessIdentity? {
        guard ttyDevice != -1, channelCreatedAt.isFinite else { return nil }
        let descriptor = open(pidFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var file = stat()
        guard fstat(descriptor, &file) == 0,
              file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == uid,
              (1...16).contains(file.st_size)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 17)
        var count: Int
        repeat {
            count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        } while count < 0 && errno == EINTR
        guard count > 0, count <= 16 else { return nil }
        var digits = bytes.prefix(count)
        if digits.last == 10 { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
              let text = String(bytes: digits, encoding: .utf8),
              let pid = pid_t(text), pid > 1,
              let process = inspect(pid),
              process.pid == pid,
              validIdentity(process, uid: uid, ttyDevice: ttyDevice),
              Double(process.startSeconds) + Double(process.startMicroseconds) / 1_000_000 >= channelCreatedAt - 1
        else { return nil }
        return process
    }

    static func chain(from peerPID: pid_t, inspect: Inspector = SSHAskpassProcessIdentity.read)
        -> [SSHAskpassProcessIdentity]? {
        var result: [SSHAskpassProcessIdentity] = []
        var pid = peerPID
        for _ in 0..<4 {
            guard let identity = inspect(pid), identity.pid == pid,
                  !result.contains(where: { $0.pid == pid })
            else { return nil }
            result.append(identity)
            pid = identity.parentPID
        }
        return result
    }

    static func validates(
        chain: [SSHAskpassProcessIdentity],
        peerUID: uid_t,
        supervisor: SSHAskpassProcessIdentity,
        appExecutablePath: String,
        uid: uid_t = getuid()
    ) -> Bool {
        guard peerUID == uid, chain.count == 4, supervisor.ttyDevice != -1,
              chain.last == supervisor,
              Set(chain.map(\.pid)).count == 4,
              chain.allSatisfy({ validIdentity($0, uid: uid, ttyDevice: supervisor.ttyDevice) }),
              chain[0].executablePath.utf8.elementsEqual(appExecutablePath.utf8),
              chain[1].executablePath.utf8.elementsEqual("/usr/bin/ssh".utf8),
              chain[2].executablePath.utf8.elementsEqual(appExecutablePath.utf8)
        else { return false }
        return zip(chain, chain.dropFirst()).allSatisfy { child, parent in
            child.parentPID == parent.pid && parent.startedNoLater(than: child)
        }
    }

    /// A tunnel's helper chain: helper → `/usr/bin/ssh` → the watchdog the app
    /// launched → the app itself. Tunnels have no terminal, so the watchdog and
    /// the app identity stand in for a pane's pinned supervisor and its tty.
    static func validatesTunnel(
        chain: [SSHAskpassProcessIdentity],
        peerUID: uid_t,
        watchdog: SSHAskpassProcessIdentity,
        owner: SSHAskpassProcessIdentity,
        appExecutablePath: String,
        uid: uid_t = getuid()
    ) -> Bool {
        guard peerUID == uid, chain.count == 4,
              Set(chain.map(\.pid)).count == 4,
              chain.allSatisfy({ validIdentity($0, uid: uid, ttyDevice: $0.ttyDevice) }),
              chain[0].executablePath.utf8.elementsEqual(appExecutablePath.utf8),
              chain[1].executablePath.utf8.elementsEqual("/usr/bin/ssh".utf8),
              chain[2].isSameProcess(as: watchdog),
              chain[3].isSameProcess(as: owner),
              chain[3].executablePath.utf8.elementsEqual(appExecutablePath.utf8)
        else { return false }
        return zip(chain, chain.dropFirst()).allSatisfy { child, parent in
            child.parentPID == parent.pid && parent.startedNoLater(than: child)
        }
    }

    private static func validIdentity(_ identity: SSHAskpassProcessIdentity, uid: uid_t, ttyDevice: dev_t) -> Bool {
        identity.pid > 1 && identity.realUID == uid && identity.effectiveUID == uid &&
            identity.ttyDevice == ttyDevice && identity.startSeconds > 0 &&
            (0..<1_000_000).contains(identity.startMicroseconds)
    }
}
