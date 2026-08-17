import Cocoa

enum CodableBridgeError: Error, Equatable {
    case innerEncodingFailed
    case payloadTooLarge
    case missingData
    case corruptData
    case secureUnarchiveFailed
}

private enum CodableBridgePayloadPolicy {
    static let maximumPayloadSize = 8 * 1024 * 1024
}

/// A wrapper that allows a Swift Codable to implement NSSecureCoding.
class CodableBridge<Wrapped: Codable>: NSObject, NSSecureCoding {
    static var maximumPayloadSize: Int { CodableBridgePayloadPolicy.maximumPayloadSize }

    let value: Wrapped
    private let archivedData: Data

    init(_ value: Wrapped) throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        do {
            try archiver.encodeEncodable(value, forKey: "value")
        } catch {
            throw CodableBridgeError.innerEncodingFailed
        }

        let archivedData = archiver.encodedData
        guard archivedData.count <= Self.maximumPayloadSize else {
            throw CodableBridgeError.payloadTooLarge
        }

        self.value = value
        self.archivedData = archivedData
    }

    static var supportsSecureCoding: Bool { return true }

    required init?(coder aDecoder: NSCoder) {
        do {
            let bridge = try Self.decode(from: aDecoder)
            self.value = bridge.value
            self.archivedData = bridge.archivedData
        } catch {
            aDecoder.failWithError(error)
            return nil
        }
    }

    static func decode(from decoder: NSCoder) throws -> CodableBridge<Wrapped> {
        guard decoder.containsValue(forKey: "data") else {
            throw CodableBridgeError.missingData
        }
        guard let data = decoder.decodeObject(of: NSData.self, forKey: "data") as? Data else {
            throw CodableBridgeError.corruptData
        }
        guard data.count <= Self.maximumPayloadSize else {
            throw CodableBridgeError.payloadTooLarge
        }

        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            throw CodableBridgeError.secureUnarchiveFailed
        }
        defer { unarchiver.finishDecoding() }

        unarchiver.requiresSecureCoding = true
        guard let value = unarchiver.decodeDecodable(Wrapped.self, forKey: "value") else {
            throw CodableBridgeError.corruptData
        }

        return CodableBridge(value: value, archivedData: data)
    }

    private init(value: Wrapped, archivedData: Data) {
        self.value = value
        self.archivedData = archivedData
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(archivedData, forKey: "data")
    }
}
