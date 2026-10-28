import Darwin
import Foundation

final class SSHRuntimeRoot {
    struct Owner: Equatable {
        let pid: Int32
        let startSeconds: Int64
        let startMicroseconds: Int64

        var text: String { "\(pid) \(startSeconds) \(startMicroseconds)\n" }
    }

    let url: URL
    private let fileManager: FileManager

    init(
        root: URL,
        processID: Int32 = getpid(),
        owner: Owner? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        url = root.appendingPathComponent(String(processID), isDirectory: true)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let identity = owner ?? Self.owner(for: processID)
        guard let identity else {
            throw CocoaError(.fileNoSuchFile)
        }
        let ownerURL = url.appendingPathComponent("owner")
        try identity.text.write(to: ownerURL, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)
    }

    func removeOwnRoot() {
        try? fileManager.removeItem(at: url)
    }

    static func reclaimStale(
        root: URL,
        fileManager: FileManager = .default,
        reaper: (URL) -> Bool = { SSHTunnelReaper.reap(in: $0) }
    ) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return }

        var reclaimed = 0
        var liveOwners = 0
        var withoutOwner = 0
        for child in children {
            guard let pid = Int32(child.lastPathComponent),
                  pid > 1,
                  isPrivateOwnedDirectory(child)
            else { continue }
            switch readOwner(in: child) {
            case .owner(let owner):
                guard shouldReclaim(owner) else { liveOwners += 1; continue }
                guard reaper(child) else { continue }
            case .missing:
                withoutOwner += 1
                guard processIsDead(pid), reaper(child) else { continue }
            case .invalid:
                continue
            }
            try? fileManager.removeItem(at: child)
            reclaimed += 1
        }
        SSHLog.logger.notice(
            "runtime.reclaimed reclaimed=\(reclaimed, privacy: .public) live=\(liveOwners, privacy: .public) noOwner=\(withoutOwner, privacy: .public)")
    }

    static func owner(for pid: Int32) -> Owner? {
        guard let info = processInfo(for: pid) else { return nil }
        return Owner(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec))
    }

    static func processInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return info
    }

    private enum OwnerFile {
        case owner(Owner)
        case missing
        case invalid
    }

    private static func readOwner(in directory: URL) -> OwnerFile {
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { return .invalid }
        defer { close(directoryDescriptor) }

        let descriptor = openat(
            directoryDescriptor,
            "owner",
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .invalid
        }
        defer { close(descriptor) }

        var file = stat()
        guard fstat(descriptor, &file) == 0,
              file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == getuid(),
              file.st_mode & 0o777 == 0o600,
              (1...128).contains(Int(file.st_size))
        else { return .invalid }

        var bytes = [UInt8](repeating: 0, count: Int(file.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count,
              let text = String(bytes: bytes, encoding: .utf8),
              let owner = parseOwner(text)
        else { return .invalid }
        return .owner(owner)
    }

    /// A real directory (not a link) owned by `uid` with mode 0700.
    static func isPrivateOwnedDirectory(_ url: URL, uid: uid_t = getuid()) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == uid
        else { return false }
        return info.st_mode & 0o777 == 0o700
    }

    private static func parseOwner(_ text: String) -> Owner? {
        let values = text.split(whereSeparator: \.isWhitespace)
        guard values.count == 3,
              let pid = Int32(values[0]),
              let seconds = Int64(values[1]),
              let microseconds = Int64(values[2]),
              pid > 1,
              seconds > 0,
              (0..<1_000_000).contains(microseconds)
        else { return nil }
        return Owner(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
    }

    private static func shouldReclaim(_ owner: Owner) -> Bool {
        guard !processIsDead(owner.pid) else { return true }
        guard let current = Self.owner(for: owner.pid) else { return false }
        return current != owner
    }

    private static func processIsDead(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == -1 else { return false }
        return errno == ESRCH
    }
}
