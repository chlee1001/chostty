import AppKit
import Testing
@testable import Ghostty

struct CodableBridgeTests {
    @Test func roundTrip() throws {
        let bridge = try CodableBridge(Payload(value: "value"))
        let data = try archive(bridge)

        let decoded: CodableBridge<Payload> = try unarchive(data)

        #expect(decoded.value == Payload(value: "value"))
    }

    @Test func encodesCachedPayload() throws {
        let payload = MutablePayload(value: "original")
        let bridge = try CodableBridge(payload)
        payload.value = "changed"

        let decoded: CodableBridge<MutablePayload> = try unarchive(archive(bridge))

        #expect(decoded.value.value == "original")
    }

    @Test func rejectsInnerEncodingFailure() {
        #expect(throws: CodableBridgeError.innerEncodingFailed) {
            try CodableBridge(ThrowingPayload())
        }
    }

    @Test func rejectsOversizedPayload() {
        let payload = Payload(value: String(repeating: "x", count: CodableBridge<Payload>.maximumPayloadSize))

        #expect(throws: CodableBridgeError.payloadTooLarge) {
            try CodableBridge(payload)
        }
    }

    @Test func rejectsMissingData() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        let data = archiver.encodedData
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding() }

        #expect(throws: CodableBridgeError.missingData) {
            try CodableBridge<Payload>.decode(from: unarchiver)
        }
    }

    @Test func rejectsCorruptData() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode("not data" as NSString, forKey: "data")
        let data = archiver.encodedData
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding() }

        #expect(throws: CodableBridgeError.corruptData) {
            try CodableBridge<Payload>.decode(from: unarchiver)
        }
    }
}

private extension CodableBridgeTests {
    struct Payload: Codable, Equatable {
        let value: String
    }

    struct ThrowingPayload: Codable {
        init() {}

        init(from decoder: Decoder) throws {}

        func encode(to encoder: Encoder) throws {
            throw FixtureError.encodingFailed
        }
    }

    enum FixtureError: Error {
        case encodingFailed
    }

    final class MutablePayload: Codable {
        var value: String

        init(value: String) {
            self.value = value
        }
    }

    func archive<T: NSObject & NSSecureCoding>(_ object: T) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    func unarchive<T: NSObject & NSSecureCoding>(_ data: Data, as type: T.Type = T.self) throws -> T {
        let object = try NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data)
        return try #require(object)
    }
}
