import Foundation

enum SSHAliasError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case nonASCII
    case leadingDash
    case unsupportedCharacter(Character)
}

enum SSHAlias {
    static func validate(_ raw: String) -> Result<String, SSHAliasError> {
        guard !raw.isEmpty else { return .failure(.empty) }
        guard raw.utf8.count <= 255 else { return .failure(.tooLong) }
        guard raw.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x21 && $0.value <= 0x7e }) else {
            return .failure(.nonASCII)
        }
        guard raw.first != "-" else { return .failure(.leadingDash) }

        let forbidden = Set("*?!,'\"\\$;|&<>()`%")
        if let character = raw.first(where: { forbidden.contains($0) }) {
            return .failure(.unsupportedCharacter(character))
        }
        return .success(raw)
    }
}
