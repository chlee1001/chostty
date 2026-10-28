import CryptoKit
import Darwin
import Foundation

enum SSHStoreError: Error, Equatable, Sendable, LocalizedError {
    case changedOnDisk
    case invalidAlias(SSHAliasError)
    case invalidScalarValue(String)
    case invalidPort
    case invalidIdentityFile(String)
    case invalidOtherLine
    case duplicateAlias(String)
    case invalidManagedBlock(UUID)
    case readFailed(Int32)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            return "The SSH hosts file changed on disk."
        case .invalidAlias:
            return "The SSH host alias is invalid."
        case .invalidScalarValue:
            return "An SSH host value contains whitespace or a control character."
        case .invalidPort:
            return "The SSH port must be between 1 and 65535."
        case .invalidIdentityFile:
            return "An identity file must be an absolute path or start with ~."
        case .invalidOtherLine:
            return "An SSH option line cannot contain a newline."
        case .duplicateAlias(let alias):
            return "The SSH host alias \(alias) is already managed."
        case .invalidManagedBlock:
            return "A managed SSH host block is invalid."
        case .readFailed:
            return "The SSH hosts file could not be read."
        case .writeFailed:
            return "The SSH hosts file could not be written."
        }
    }
}

struct SSHFileContents: Equatable, Sendable {
    let data: Data?
    let hash: Data?
}

struct SSHSecureFileWriter {
    enum FailurePoint: Equatable, Sendable {
        case beforeWrite
    }

    private let failurePoint: FailurePoint?

    init(failurePoint: FailurePoint? = nil) {
        self.failurePoint = failurePoint
    }

    func read(at url: URL) throws -> SSHFileContents {
        do {
            let data = try Data(contentsOf: Self.resolvedTarget(of: url))
            return SSHFileContents(data: data, hash: Self.hash(of: data))
        } catch let error as SSHStoreError {
            throw error
        } catch {
            if Self.isMissingFile(error) {
                return SSHFileContents(data: nil, hash: nil)
            }
            let code = Self.errorCode(error)
            throw SSHStoreError.readFailed(code)
        }
    }

    func write(_ data: Data, to url: URL, expectedHash: Data?) throws {
        let target = try Self.resolvedTarget(of: url)
        let current = try read(at: target)
        guard current.hash == expectedHash else {
            throw SSHStoreError.changedOnDisk
        }

        try createParentDirectories(of: target)
        let (temporary, descriptor) = try createTemporaryFile(near: target)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                _ = Darwin.unlink(temporary.path)
            }
        }
        defer { _ = Darwin.close(descriptor) }

        if failurePoint == .beforeWrite {
            throw SSHStoreError.writeFailed(EIO)
        }
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw SSHStoreError.writeFailed(errno)
        }
        guard try read(at: target).hash == expectedHash else {
            throw SSHStoreError.changedOnDisk
        }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw SSHStoreError.writeFailed(errno)
        }
        shouldRemoveTemporary = false
    }

    static func hash(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func createParentDirectories(of target: URL) throws {
        let components = target.deletingLastPathComponent().standardizedFileURL.pathComponents
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            directory.appendPathComponent(component, isDirectory: true)
            if Darwin.mkdir(directory.path, 0o700) != 0, errno != EEXIST {
                throw SSHStoreError.writeFailed(errno)
            }
        }
    }

    private func createTemporaryFile(near target: URL) throws -> (URL, Int32) {
        let directory = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        for _ in 0..<16 {
            let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor >= 0 {
                return (temporary, descriptor)
            }
            if errno != EEXIST {
                throw SSHStoreError.writeFailed(errno)
            }
        }
        throw SSHStoreError.writeFailed(EEXIST)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw SSHStoreError.writeFailed(written == 0 ? EIO : errno)
            }
        }
    }

    // URL.resolvingSymlinksInPath leaves a dangling final symlink unresolved.
    private static func resolvedTarget(of url: URL) throws -> URL {
        var target = url.standardizedFileURL
        var visited = Set<String>()
        for _ in 0..<40 {
            let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
            target = parent.appendingPathComponent(target.lastPathComponent)
            var attributes = stat()
            if lstat(target.path, &attributes) != 0 {
                guard errno == ENOENT || errno == ENOTDIR else {
                    throw SSHStoreError.readFailed(errno)
                }
                return target
            }
            guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { return target }
            guard visited.insert(target.path).inserted else { throw SSHStoreError.readFailed(ELOOP) }
            let destination: String
            do {
                destination = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
            } catch {
                throw SSHStoreError.readFailed(errorCode(error))
            }
            target = (destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : parent.appendingPathComponent(destination)).standardizedFileURL
        }
        throw SSHStoreError.readFailed(ELOOP)
    }

    private static func errorCode(_ error: Error) -> Int32 {
        if let error = error as? POSIXError {
            return Int32(error.errorCode)
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return Int32(truncatingIfNeeded: error.code)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return errorCode(underlying)
        }
        return Int32(truncatingIfNeeded: error.code)
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        if let error = error as? POSIXError {
            return error.code == .ENOENT || error.code == .ENOTDIR
        }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ENOENT) || error.code == Int(ENOTDIR)
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingFile(underlying)
        }
        return false
    }
}
