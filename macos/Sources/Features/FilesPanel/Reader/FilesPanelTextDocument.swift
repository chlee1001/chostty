import Foundation

struct FilesPanelTextDocument: Equatable, Sendable {
    let sourcePath: String
    let text: String

    var estimatedByteCost: Int { text.utf8.count }
    var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
}
