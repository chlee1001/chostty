import Foundation

struct SSHBindConsent: Codable, Equatable, Sendable {
    let address: String
    let port: Int
    let kind: SSHTunnelDefinition.Kind
    let grantedAt: Date

    static func requiresConsent(for bindAddress: String) -> Bool {
        switch bindAddress.lowercased() {
        case "127.0.0.1", "::1", "[::1]", "localhost":
            return false
        default:
            return true
        }
    }

    func matches(address: String, port: Int, kind: SSHTunnelDefinition.Kind) -> Bool {
        self.address == address && self.port == port && self.kind == kind
    }
}
