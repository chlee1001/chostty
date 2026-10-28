import Darwin
import Foundation

enum SSHTunnelReaper {
    private struct Record: Codable {
        let id: UUID
        let pid: pid_t
        let realUID: uid_t
        let effectiveUID: uid_t
        let startSeconds: Int64
        let startMicroseconds: Int64
        let executablePath: String

        init(id: UUID, process: SSHAskpassProcessIdentity) {
            self.id = id
            pid = process.pid
            realUID = process.realUID
            effectiveUID = process.effectiveUID
            startSeconds = process.startSeconds
            startMicroseconds = process.startMicroseconds
            executablePath = process.executablePath
        }

        func matches(_ process: SSHAskpassProcessIdentity, uid: uid_t) -> Bool {
            pid > 1 &&
                realUID == uid &&
                effectiveUID == uid &&
                process.pid == pid &&
                process.realUID == realUID &&
                process.effectiveUID == effectiveUID &&
                process.startSeconds == startSeconds &&
                process.startMicroseconds == startMicroseconds &&
                process.executablePath.utf8.elementsEqual(executablePath.utf8)
        }
    }

    typealias Inspector = (pid_t) -> SSHAskpassProcessIdentity?
    typealias Signaler = (pid_t, Int32) -> Int32
    typealias Waiter = (useconds_t) -> Void

    private static let maximumRecordSize = 16 * 1024

    static func writeRecord(
        for tunnelID: UUID,
        sshPID: pid_t,
        in runtimeRoot: URL
    ) throws -> URL {
        let uid = getuid()
        guard sshPID > 1,
              let process = SSHAskpassProcessIdentity.read(sshPID),
              process.pid == sshPID,
              process.realUID == uid,
              process.effectiveUID == uid,
              process.startSeconds > 0,
              (0..<1_000_000).contains(process.startMicroseconds),
              process.executablePath.hasPrefix("/")
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = try prepareTunnelDirectory(in: runtimeRoot, uid: uid)
        let record = Record(id: tunnelID, process: process)
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumRecordSize else { throw CocoaError(.fileWriteFileExists) }

        let url = directory.appendingPathComponent("\(tunnelID.uuidString).json")
        try atomicallyWrite(data, to: url)
        return url
    }

    static func removeRecord(for tunnelID: UUID, in runtimeRoot: URL) {
        _ = discardRecord(tunnelID, in: runtimeRoot)
    }

    // Returns false when an owned process could not be conclusively reaped.
    static func reap(
        in runtimeRoot: URL,
        inspect: Inspector = SSHAskpassProcessIdentity.read,
        signal: Signaler = { pid, signal in Darwin.kill(pid, signal) },
        wait: Waiter = { usleep($0) }
    ) -> Bool {
        let uid = getuid()
        guard SSHRuntimeRoot.isPrivateOwnedDirectory(runtimeRoot, uid: uid) else { return false }
        let directory = runtimeRoot.appendingPathComponent("tunnels", isDirectory: true)

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            return errno == ENOENT
        }
        guard SSHRuntimeRoot.isPrivateOwnedDirectory(directory, uid: uid) else { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [])
        else { return false }

        // An unreadable entry fails the pass but does not shield the records
        // after it.
        var readable = true
        for entry in entries {
            // An interrupted atomic write leaves only its temporary file; the
            // record it would have become was never published.
            if entry.lastPathComponent.hasPrefix("."), entry.lastPathComponent.hasSuffix(".tmp") {
                _ = unlink(entry.path)
                continue
            }
            guard let record = readRecord(at: entry),
                  entry.lastPathComponent == "\(record.id.uuidString).json"
            else {
                readable = false
                continue
            }

            guard let current = inspect(record.pid) else {
                guard discardRecord(record.id, in: runtimeRoot) else { return false }
                continue
            }
            guard record.matches(current, uid: uid) else {
                guard discardRecord(record.id, in: runtimeRoot) else { return false }
                continue
            }

            guard inspect(record.pid).map({ record.matches($0, uid: uid) }) == true else {
                guard discardRecord(record.id, in: runtimeRoot) else { return false }
                continue
            }
            _ = signal(record.pid, SIGTERM)

            if waitForExit(record, uid: uid, inspect: inspect, wait: wait) {
                guard discardRecord(record.id, in: runtimeRoot) else { return false }
                continue
            }

            guard inspect(record.pid).map({ record.matches($0, uid: uid) }) == true else {
                guard discardRecord(record.id, in: runtimeRoot) else { return false }
                continue
            }
            _ = signal(record.pid, SIGKILL)

            guard waitForExit(record, uid: uid, inspect: inspect, wait: wait) else {
                return false
            }
            guard discardRecord(record.id, in: runtimeRoot) else { return false }
        }
        return readable
    }

    private static func waitForExit(
        _ record: Record,
        uid: uid_t,
        inspect: Inspector,
        wait: Waiter
    ) -> Bool {
        for _ in 0..<20 {
            wait(100_000)
            guard let current = inspect(record.pid) else { return true }
            guard record.matches(current, uid: uid) else { return true }
        }
        return false
    }

    private static func prepareTunnelDirectory(in runtimeRoot: URL, uid: uid_t) throws -> URL {
        guard SSHRuntimeRoot.isPrivateOwnedDirectory(runtimeRoot, uid: uid) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = runtimeRoot.appendingPathComponent("tunnels", isDirectory: true)
        var info = stat()
        if lstat(directory.path, &info) == -1 {
            guard errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        guard SSHRuntimeRoot.isPrivateOwnedDirectory(directory, uid: uid) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory
    }

    private static func atomicallyWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists) }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { _ = unlink(temporary.path) }
        }

        try writeAll(data, to: descriptor)
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0,
              rename(temporary.path, url.path) == 0
        else { throw CocoaError(.fileWriteUnknown) }
        succeeded = true
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func readRecord(at url: URL) -> Record? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var file = stat()
        guard fstat(descriptor, &file) == 0,
              file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == getuid(),
              file.st_mode & 0o777 == 0o600,
              (1...maximumRecordSize).contains(Int(file.st_size))
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: Int(file.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count,
              let record = try? JSONDecoder().decode(Record.self, from: Data(bytes)),
              record.pid > 1,
              record.realUID == getuid(),
              record.effectiveUID == getuid(),
              record.startSeconds > 0,
              (0..<1_000_000).contains(record.startMicroseconds),
              record.executablePath.hasPrefix("/")
        else { return nil }
        return record
    }

    private static func discardRecord(_ tunnelID: UUID, in runtimeRoot: URL) -> Bool {
        let url = runtimeRoot
            .appendingPathComponent("tunnels", isDirectory: true)
            .appendingPathComponent("\(tunnelID.uuidString).json")
        guard let record = readRecord(at: url), record.id == tunnelID else { return false }
        guard unlink(url.path) == 0 else { return errno == ENOENT }
        var info = stat()
        return lstat(url.path, &info) == -1 && errno == ENOENT
    }
}
