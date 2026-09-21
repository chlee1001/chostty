#!/usr/bin/env swift

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sparkle-public-key.swift <private-key-file>\n".utf8))
    exit(2)
}

do {
    let encoded = try String(
        contentsOfFile: CommandLine.arguments[1],
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: encoded) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("invalid Sparkle private key: \(error)\n".utf8))
    exit(1)
}
