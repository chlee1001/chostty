import Darwin
import Foundation
@preconcurrency import Security

struct SSHTargetFingerprint: Equatable, Sendable {
    let hostID: UUID
    let user: String
    let hostName: String
    let port: Int
    let serialized: Data

    var displayDestination: String {
        "\(user)@\(hostName):\(port)"
    }

    init(hostID: UUID, user: String, hostName: String, port: Int) throws {
        guard Self.isValidScalar(user),
              Self.isValidHostName(hostName),
              (1...65535).contains(port)
        else {
            throw SSHSecretStoreError.malformedTarget
        }

        self.hostID = hostID
        self.user = user
        self.hostName = hostName
        self.port = port
        self.serialized = Data("v1|\(hostID.uuidString)|\(user)@\(hostName):\(port)".utf8)
    }

    static func decode(_ data: Data, for hostID: UUID) throws -> Self {
        guard let string = String(data: data, encoding: .utf8) else {
            throw SSHSecretStoreError.malformedTarget
        }
        let components = string.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1",
              let storedHostID = UUID(uuidString: String(components[1])),
              storedHostID == hostID,
              let portSeparator = components[2].lastIndex(of: ":"),
              let accountSeparator = components[2][..<portSeparator].lastIndex(of: "@"),
              let port = Int(components[2][components[2].index(after: portSeparator)...])
        else {
            throw SSHSecretStoreError.malformedTarget
        }

        let user = String(components[2][..<accountSeparator])
        let hostName = String(components[2][components[2].index(after: accountSeparator)..<portSeparator])
        let fingerprint = try Self(hostID: storedHostID, user: user, hostName: hostName, port: port)
        guard fingerprint.serialized == data else {
            throw SSHSecretStoreError.malformedTarget
        }
        return fingerprint
    }

    private static func isValidScalar(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.controlCharacters.contains($0) &&
                $0 != "|"
        }
    }

    private static func isValidHostName(_ value: String) -> Bool {
        isValidScalar(value) && !value.contains("@")
    }
}

// One operation owns this non-Sendable buffer; borrowed views must not escape.
final class SSHSecretBuffer {
    let count: Int
    private let storage: UnsafeMutableRawPointer

    private init(allocating count: Int) {
        self.count = count
        storage = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1))
    }

    convenience init(copying source: UnsafeRawBufferPointer) {
        self.init(allocating: source.count)
        if count > 0 {
            storage.copyMemory(from: source.baseAddress!, byteCount: count)
        }
    }

    convenience init(copying source: CFData) {
        let count = CFDataGetLength(source)
        self.init(copying: UnsafeRawBufferPointer(start: CFDataGetBytePtr(source), count: count))
    }

    convenience init(count: Int, initializing body: (UnsafeMutableRawBufferPointer) throws -> Void) throws {
        guard (1...1023).contains(count) else { throw SSHSecretStoreError.invalidSecret }
        self.init(allocating: count)
        try body(UnsafeMutableRawBufferPointer(start: storage, count: count))
    }

    func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: storage, count: count))
    }

    func wipe() {
        _ = memset_s(storage, max(count, 1), 0, max(count, 1))
    }

    deinit {
        wipe()
        storage.deallocate()
    }
}

enum SSHSecretStoreError: Error, Equatable, Sendable {
    case notFound
    case locked
    case denied
    case malformedTarget
    case targetMismatch
    case invalidSecret
    case unexpected(OSStatus)
}

protocol SSHSecretStore: Sendable {
    func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer
    func target(for hostID: UUID) throws -> SSHTargetFingerprint
    func setPassword(_ secret: SSHSecretBuffer, for hostID: UUID, target: SSHTargetFingerprint, label: String) throws
    func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws
    func deletePassword(for hostID: UUID) throws
}

protocol SSHKeychainSecItemClient: Sendable {
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemSSHKeychainSecItemClient: SSHKeychainSecItemClient {
    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

struct KeychainSSHSecretStore: SSHSecretStore {
    private let service: String
    private let client: any SSHKeychainSecItemClient

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "kr.co.devch.chostty",
        client: any SSHKeychainSecItemClient = SystemSSHKeychainSecItemClient()
    ) {
        service = "\(bundleIdentifier).ssh.password"
        self.client = client
    }

    func password(for hostID: UUID, matching target: SSHTargetFingerprint) throws -> SSHSecretBuffer {
        try validate(target: target, for: hostID)
        var query = itemAttributes(for: hostID)
        query[Key.returnAttributes] = true
        query[Key.returnData] = true
        query[Key.matchLimit] = kSecMatchLimitOne

        let response = client.copyMatching(dictionary(query))
        try check(response.status)
        guard let result = response.result,
              CFGetTypeID(result) == CFDictionaryGetTypeID()
        else {
            throw SSHSecretStoreError.malformedTarget
        }
        let attributes = unsafeBitCast(result, to: CFDictionary.self)
        guard let generic = cfData(in: attributes, key: kSecAttrGeneric),
              let secretData = cfData(in: attributes, key: kSecValueData)
        else {
            throw SSHSecretStoreError.malformedTarget
        }

        let storedTarget = try fingerprint(copying: generic, for: hostID)
        guard storedTarget == target, target.serialized == data(copying: generic) else {
            throw SSHSecretStoreError.targetMismatch
        }
        guard (1...1023).contains(CFDataGetLength(secretData)) else {
            throw SSHSecretStoreError.invalidSecret
        }

        let secret = SSHSecretBuffer(copying: secretData)
        do {
            try validate(secret: secret)
            return secret
        } catch {
            secret.wipe()
            throw error
        }
    }

    func target(for hostID: UUID) throws -> SSHTargetFingerprint {
        var query = itemAttributes(for: hostID)
        query[Key.authenticationUI] = kSecUseAuthenticationUIFail
        query[Key.returnAttributes] = true
        query[Key.matchLimit] = kSecMatchLimitOne

        let response = client.copyMatching(dictionary(query))
        try check(response.status)
        guard let result = response.result,
              CFGetTypeID(result) == CFDictionaryGetTypeID(),
              let generic = cfData(in: unsafeBitCast(result, to: CFDictionary.self), key: kSecAttrGeneric)
        else {
            throw SSHSecretStoreError.malformedTarget
        }
        return try fingerprint(copying: generic, for: hostID)
    }

    func setPassword(_ secret: SSHSecretBuffer, for hostID: UUID, target: SSHTargetFingerprint, label: String) throws {
        try validate(target: target, for: hostID)
        try validate(secret: secret)
        let status = try secret.withUnsafeBytes { bytes in
            try autoreleasepool {
                guard let value = CFDataCreateWithBytesNoCopy(
                    kCFAllocatorDefault,
                    bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bytes.count,
                    kCFAllocatorNull)
                else {
                    throw SSHSecretStoreError.unexpected(errSecAllocate)
                }
                var attributes = itemAttributes(for: hostID)
                attributes[Key.valueData] = value
                attributes[Key.generic] = target.serialized
                attributes[Key.label] = label
                let addStatus = client.add(dictionary(attributes))
                if addStatus == errSecDuplicateItem {
                    let updates: [String: Any] = [
                        Key.valueData: value,
                        Key.generic: target.serialized,
                        Key.label: label,
                    ]
                    return client.update(dictionary(itemAttributes(for: hostID)), attributes: dictionary(updates))
                }
                return addStatus
            }
        }
        try check(status)
    }

    func updateTarget(_ target: SSHTargetFingerprint, for hostID: UUID) throws {
        try validate(target: target, for: hostID)
        try check(client.update(
            dictionary(itemAttributes(for: hostID)),
            attributes: dictionary([Key.generic: target.serialized])))
    }

    func deletePassword(for hostID: UUID) throws {
        let status = client.delete(dictionary(itemAttributes(for: hostID)))
        guard status != errSecItemNotFound else { return }
        try check(status)
    }

    private func itemAttributes(for hostID: UUID) -> [String: Any] {
        [
            Key.itemClass: kSecClassGenericPassword,
            Key.service: service,
            Key.account: hostID.uuidString,
            Key.synchronizable: false,
            Key.dataProtection: false,
        ]
    }

    private func validate(target: SSHTargetFingerprint, for hostID: UUID) throws {
        guard target.hostID == hostID,
              try SSHTargetFingerprint.decode(target.serialized, for: hostID) == target
        else {
            throw SSHSecretStoreError.malformedTarget
        }
    }

    private func validate(secret: SSHSecretBuffer) throws {
        guard (1...1023).contains(secret.count) else {
            throw SSHSecretStoreError.invalidSecret
        }
        let valid = secret.withUnsafeBytes { bytes in
            !bytes.contains(0) && !bytes.contains(10) && !bytes.contains(13)
        }
        guard valid else { throw SSHSecretStoreError.invalidSecret }
    }

    private func fingerprint(copying data: CFData, for hostID: UUID) throws -> SSHTargetFingerprint {
        try SSHTargetFingerprint.decode(self.data(copying: data), for: hostID)
    }

    private func data(copying data: CFData) -> Data {
        let count = CFDataGetLength(data)
        guard count > 0 else { return Data() }
        return Data(bytes: CFDataGetBytePtr(data)!, count: count)
    }

    private func cfData(in dictionary: CFDictionary, key: CFString) -> CFData? {
        guard let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()),
              CFGetTypeID(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()) == CFDataGetTypeID()
        else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue()
    }

    private func dictionary(_ values: [String: Any]) -> CFDictionary {
        values as CFDictionary
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw SSHSecretStoreError.notFound
        case errSecInteractionNotAllowed:
            throw SSHSecretStoreError.locked
        case errSecAuthFailed, errSecUserCanceled:
            throw SSHSecretStoreError.denied
        default:
            throw SSHSecretStoreError.unexpected(status)
        }
    }

    private enum Key {
        static let itemClass = kSecClass as String
        static let service = kSecAttrService as String
        static let account = kSecAttrAccount as String
        static let generic = kSecAttrGeneric as String
        static let label = kSecAttrLabel as String
        static let synchronizable = kSecAttrSynchronizable as String
        static let dataProtection = kSecUseDataProtectionKeychain as String
        static let authenticationUI = kSecUseAuthenticationUI as String
        static let matchLimit = kSecMatchLimit as String
        static let returnAttributes = kSecReturnAttributes as String
        static let returnData = kSecReturnData as String
        static let valueData = kSecValueData as String
    }
}
