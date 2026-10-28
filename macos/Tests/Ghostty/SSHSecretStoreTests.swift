import Foundation
import Security
import Testing
@testable import Ghostty

struct SSHSecretStoreTests {
    @Test func fillsOwnedBufferDirectlyAndWipesIt() throws {
        let buffer = try SSHSecretBuffer(count: 3) { bytes in
            bytes[0] = 1
            bytes[1] = 2
            bytes[2] = 3
        }
        #expect(bytes(buffer) == [1, 2, 3])
        buffer.wipe()
        #expect(bytes(buffer) == [0, 0, 0])
    }

    @Test(arguments: [-1, 0, 1024])
    func rejectsInvalidDirectFillLengthsBeforeCallingTheWriter(_ count: Int) {
        var called = false
        #expect(throws: SSHSecretStoreError.invalidSecret) {
            try SSHSecretBuffer(count: count) { _ in called = true }
        }
        #expect(!called)
    }

    @Test func propagatesDirectFillFailure() {
        #expect(throws: SSHSecretStoreError.denied) {
            try SSHSecretBuffer(count: 3) { bytes in
                bytes[0] = 1
                throw SSHSecretStoreError.denied
            }
        }
    }

    @Test func fingerprintIsStrictAndCanonical() throws {
        let hostID = UUID()
        let fingerprint = try SSHTargetFingerprint(hostID: hostID, user: "build@corp", hostName: "2001:db8::1", port: 2222)

        #expect(fingerprint.displayDestination == "build@corp@2001:db8::1:2222")
        #expect(try SSHTargetFingerprint.decode(fingerprint.serialized, for: hostID) == fingerprint)
        #expect(throws: SSHSecretStoreError.malformedTarget) {
            try SSHTargetFingerprint.decode(Data("v1|\(hostID.uuidString)|build@corp@2001:db8::1:2222 ".utf8), for: hostID)
        }
        #expect(throws: SSHSecretStoreError.malformedTarget) {
            try SSHTargetFingerprint(hostID: hostID, user: "build\nuser", hostName: "host", port: 22)
        }
        #expect(throws: SSHSecretStoreError.malformedTarget) {
            try SSHTargetFingerprint(hostID: hostID, user: "build", hostName: "bad@host", port: 22)
        }

        let expected = try SSHTargetFingerprint(hostID: hostID, user: "café", hostName: "host", port: 22)
        let differentlyEncoded = try SSHTargetFingerprint(hostID: hostID, user: "cafe\u{301}", hostName: "host", port: 22)
        let fake = FakeSecItemClient()
        fake.result = fake.result(generic: differentlyEncoded.serialized, secret: [115])
        #expect(throws: SSHSecretStoreError.targetMismatch) {
            try KeychainSSHSecretStore(client: fake).password(for: hostID, matching: expected)
        }
    }

    @Test func targetPreflightIsUIlessAndNeverRequestsData() throws {
        let hostID = UUID()
        let fake = FakeSecItemClient()
        fake.result = fake.result(generic: try fingerprint(hostID).serialized)
        let store = KeychainSSHSecretStore(bundleIdentifier: "kr.co.devch.chostty.debug", client: fake)

        _ = try store.target(for: hostID)
        let query = try #require(fake.copyQueries.last)
        #expect(fake.string(query, kSecAttrService) == "kr.co.devch.chostty.debug.ssh.password")
        #expect(fake.string(query, kSecAttrAccount) == hostID.uuidString)
        #expect(fake.bool(query, kSecAttrSynchronizable) == false)
        #expect(fake.bool(query, kSecUseDataProtectionKeychain) == false)
        #expect(fake.string(query, kSecUseAuthenticationUI) == (kSecUseAuthenticationUIFail as String))
        #expect(fake.bool(query, kSecReturnAttributes) == true)
        #expect(fake.value(query, kSecReturnData) == nil)
    }

    @Test func passwordFetchIsAtomicAllowsSecurityUIAndMatchesTargetBytes() throws {
        let hostID = UUID()
        let fake = FakeSecItemClient()
        let target = try fingerprint(hostID)
        fake.result = fake.result(generic: target.serialized, secret: [115, 101, 99, 114, 101, 116])
        let store = KeychainSSHSecretStore(client: fake)

        let result = try store.password(for: hostID, matching: target)
        #expect(bytes(result) == [115, 101, 99, 114, 101, 116])
        #expect(fake.copyQueries.count == 1)
        let query = fake.copyQueries[0]
        #expect(fake.bool(query, kSecReturnAttributes) == true)
        #expect(fake.bool(query, kSecReturnData) == true)
        #expect(fake.value(query, kSecUseAuthenticationUI) == nil)

        fake.result = fake.result(generic: try fingerprint(UUID()).serialized, secret: [115])
        #expect(throws: SSHSecretStoreError.malformedTarget) {
            try store.password(for: hostID, matching: target)
        }
        fake.result = fake.result(generic: try SSHTargetFingerprint(hostID: hostID, user: "other", hostName: "host", port: 22).serialized, secret: [115])
        #expect(throws: SSHSecretStoreError.targetMismatch) {
            try store.password(for: hostID, matching: target)
        }
    }

    @Test(arguments: [0, 1, 1022, 1023, 1024])
    func validatesFetchedAndSetSecretLengths(_ count: Int) throws {
        let hostID = UUID()
        let target = try fingerprint(hostID)
        let bytes = Array(repeating: UInt8(97), count: count)
        let fake = FakeSecItemClient()
        fake.result = fake.result(generic: target.serialized, secret: bytes)
        let store = KeychainSSHSecretStore(client: fake)
        let buffer = buffer(bytes)

        if (1...1023).contains(count) {
            #expect(try store.password(for: hostID, matching: target).count == count)
            try store.setPassword(buffer, for: hostID, target: target, label: "host")
        } else {
            #expect(throws: SSHSecretStoreError.invalidSecret) {
                try store.password(for: hostID, matching: target)
            }
            #expect(throws: SSHSecretStoreError.invalidSecret) {
                try store.setPassword(buffer, for: hostID, target: target, label: "host")
            }
        }
    }

    @Test(arguments: [UInt8(0), UInt8(10), UInt8(13)])
    func rejectsForbiddenSecretBytes(_ forbidden: UInt8) throws {
        let hostID = UUID()
        let target = try fingerprint(hostID)
        let fake = FakeSecItemClient()
        fake.result = fake.result(generic: target.serialized, secret: [forbidden])
        let store = KeychainSSHSecretStore(client: fake)

        #expect(throws: SSHSecretStoreError.invalidSecret) {
            try store.password(for: hostID, matching: target)
        }
        #expect(throws: SSHSecretStoreError.invalidSecret) {
            try store.setPassword(buffer([forbidden]), for: hostID, target: target, label: "host")
        }
    }

    @Test func writesAreAtomicAndTargetUpdateDoesNotWriteSecretBytes() throws {
        let hostID = UUID()
        let fake = FakeSecItemClient()
        let target = try fingerprint(hostID)
        let replacement = try SSHTargetFingerprint(hostID: hostID, user: "other", hostName: "host", port: 2200)
        let store = KeychainSSHSecretStore(client: fake)

        try store.setPassword(buffer([115, 101, 99, 114, 101, 116]), for: hostID, target: target, label: "host")
        let add = try #require(fake.adds.last)
        #expect(add.secret == [115, 101, 99, 114, 101, 116])
        #expect(add.generic == target.serialized)

        fake.addStatus = errSecDuplicateItem
        try store.setPassword(buffer([114, 101, 112, 108, 97, 99, 101]), for: hostID, target: replacement, label: "host")
        let passwordUpdate = try #require(fake.updates.last)
        #expect(passwordUpdate.secret == [114, 101, 112, 108, 97, 99, 101])
        #expect(passwordUpdate.generic == replacement.serialized)

        try store.updateTarget(target, for: hostID)
        let targetUpdate = try #require(fake.updates.last)
        #expect(targetUpdate.secret == nil)
        #expect(targetUpdate.generic == target.serialized)
    }

    @Test func bufferWipesIdempotentlyAndInvalidFetchWipesDiscardedBuffer() throws {
        let buffer = buffer([115, 101, 99, 114, 101, 116])
        buffer.wipe()
        buffer.wipe()
        #expect(bytes(buffer) == Array(repeating: 0, count: 6))

        let hostID = UUID()
        let target = try fingerprint(hostID)
        let fake = FakeSecItemClient()
        fake.result = fake.result(generic: target.serialized, secret: [10])
        let store = KeychainSSHSecretStore(client: fake)
        #expect(throws: SSHSecretStoreError.invalidSecret) {
            try store.password(for: hostID, matching: target)
        }
        #expect(fake.copyQueries.count == 1)
    }

    @Test func mapsClosedStatusesAndMakesMissingDeletionIdempotent() throws {
        let hostID = UUID()
        let fake = FakeSecItemClient()
        let store = KeychainSSHSecretStore(client: fake)

        fake.copyStatus = errSecInteractionNotAllowed
        #expect(throws: SSHSecretStoreError.locked) { try store.target(for: hostID) }
        fake.copyStatus = errSecAuthFailed
        #expect(throws: SSHSecretStoreError.denied) { try store.target(for: hostID) }
        fake.copyStatus = -12345
        #expect(throws: SSHSecretStoreError.unexpected(-12345)) { try store.target(for: hostID) }
        fake.deleteStatus = errSecItemNotFound
        try store.deletePassword(for: hostID)
    }

    private func fingerprint(_ hostID: UUID) throws -> SSHTargetFingerprint {
        try SSHTargetFingerprint(hostID: hostID, user: "build", hostName: "host", port: 22)
    }

    private func buffer(_ bytes: [UInt8]) -> SSHSecretBuffer {
        bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) }
    }

    private func bytes(_ buffer: SSHSecretBuffer) -> [UInt8] {
        buffer.withUnsafeBytes { Array($0) }
    }
}

private final class FakeSecItemClient: SSHKeychainSecItemClient, @unchecked Sendable {
    struct Write {
        let secret: [UInt8]?
        let generic: Data?
    }

    var copyStatus: OSStatus = errSecSuccess
    var result: CFTypeRef?
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var copyQueries: [CFDictionary] = []
    var adds: [Write] = []
    var updates: [Write] = []

    func result(generic: Data, secret: [UInt8]? = nil) -> CFDictionary {
        var values: [String: Any] = [kSecAttrGeneric as String: cfData(generic)]
        if let secret { values[kSecValueData as String] = cfData(Data(secret)) }
        return values as CFDictionary
    }

    func copyMatching(_ query: CFDictionary) -> (status: OSStatus, result: CFTypeRef?) {
        copyQueries.append(query)
        return (copyStatus, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        adds.append(write(attributes))
        return addStatus
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        updates.append(write(attributes))
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteStatus
    }

    func value(_ dictionary: CFDictionary, _ key: CFString) -> UnsafeRawPointer? {
        CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque())
    }

    func string(_ dictionary: CFDictionary, _ key: CFString) -> String? {
        guard let value = value(dictionary, key) else { return nil }
        return unsafeBitCast(value, to: CFString.self) as String
    }

    func bool(_ dictionary: CFDictionary, _ key: CFString) -> Bool? {
        guard let value = value(dictionary, key) else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private func write(_ attributes: CFDictionary) -> Write {
        Write(
            secret: value(attributes, kSecValueData).map { cfBytes(unsafeBitCast($0, to: CFData.self)) },
            generic: value(attributes, kSecAttrGeneric).map { Data(cfBytes(unsafeBitCast($0, to: CFData.self))) })
    }

    private func cfData(_ data: Data) -> CFData {
        data.withUnsafeBytes {
            CFDataCreate(kCFAllocatorDefault, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count)!
        }
    }

    private func cfBytes(_ data: CFData) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }
}
