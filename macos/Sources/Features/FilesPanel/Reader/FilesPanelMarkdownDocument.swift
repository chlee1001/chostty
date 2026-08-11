import Foundation

struct FilesPanelMarkdownDocument: Equatable, Sendable {
    let sourcePath: String
    let source: String

    var baseURL: URL { URL(fileURLWithPath: sourcePath).deletingLastPathComponent() }
    var estimatedByteCost: Int { source.utf8.count }
}
