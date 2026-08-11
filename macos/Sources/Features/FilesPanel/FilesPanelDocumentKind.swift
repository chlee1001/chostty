import Foundation

// simplification: v1 classifies by extension plus a small prefix probe; add UniformTypeIdentifiers only if unsupported formats need richer detection.
enum FilesPanelDocumentKind: Equatable, Sendable {
    static let maximumTextBytes: Int64 = 5 * 1024 * 1024
    static let maximumImageBytes: Int64 = 32 * 1024 * 1024

    case markdown
    case text
    case image
    case pdf
    case binary
    case tooLarge(limitBytes: Int64)

    static func classify(path: String, sizeBytes: Int64) -> FilesPanelDocumentKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            return sizeBytes <= maximumImageBytes ? .image : .tooLarge(limitBytes: maximumImageBytes)
        }
        if ext == "pdf" { return .pdf }
        if markdownExtensions.contains(ext) {
            return sizeBytes <= maximumTextBytes ? .markdown : .tooLarge(limitBytes: maximumTextBytes)
        }
        if textExtensions.contains(ext) || ext.isEmpty {
            return sizeBytes <= maximumTextBytes ? .text : .tooLarge(limitBytes: maximumTextBytes)
        }
        return .binary
    }

    static func classifyContent(prefix: Data) -> FilesPanelDocumentKind? {
        if prefix.starts(with: Data("%PDF-".utf8)) { return .pdf }
        if prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) ||
            prefix.starts(with: Data([0xFF, 0xD8, 0xFF])) ||
            prefix.starts(with: Data("GIF8".utf8)) {
            return .image
        }
        if prefix.contains(0) { return .binary }
        return nil
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss",
        "swift", "zig", "c", "h", "cc", "cpp", "hpp", "m", "mm", "py", "rb", "rs", "go", "js", "jsx", "ts", "tsx",
        "sh", "bash", "zsh", "fish", "nu", "sql", "ini", "conf", "cfg", "env", "gitignore", "dockerfile", "makefile",
    ]
}
