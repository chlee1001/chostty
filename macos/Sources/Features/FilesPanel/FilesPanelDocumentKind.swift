import Foundation
import UniformTypeIdentifiers

enum FilesPanelDocumentKind: Equatable, Sendable {
    static let maximumTextBytes: Int64 = 5 * 1024 * 1024
    static let maximumImageBytes: Int64 = 32 * 1024 * 1024

    case markdown
    case text
    case structured(FilesPanelStructuredDocument.Format)
    case html
    case image
    case pdf
    case binary
    case tooLarge(limitBytes: Int64)

    static func classify(path: String, sizeBytes: Int64) -> FilesPanelDocumentKind {
        classify(path: path, sizeBytes: sizeBytes, prefix: nil)
    }

    static func classify(path: String, sizeBytes: Int64, prefix: Data?) -> FilesPanelDocumentKind {
        if let prefix, let magicKind = classifyMagic(prefix: prefix) {
            return applyingSizeLimit(to: magicKind, sizeBytes: sizeBytes)
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), let kind = classify(type: type) {
            return applyingSizeLimit(to: kind, sizeBytes: sizeBytes)
        }

        if let prefix,
           let contentKind = classifyTextPrefix(prefix),
           ext.isEmpty || !knownExtensions.contains(ext) {
            return applyingSizeLimit(to: contentKind, sizeBytes: sizeBytes)
        }

        if imageExtensions.contains(ext) {
            return applyingSizeLimit(to: .image, sizeBytes: sizeBytes)
        }
        if ext == "pdf" { return .pdf }
        if markdownExtensions.contains(ext) {
            return applyingSizeLimit(to: .markdown, sizeBytes: sizeBytes)
        }
        if let format = structuredExtensions[ext] {
            return applyingSizeLimit(to: .structured(format), sizeBytes: sizeBytes)
        }
        if ext == "html" || ext == "htm" {
            return applyingSizeLimit(to: .html, sizeBytes: sizeBytes)
        }
        if textExtensions.contains(ext) || ext.isEmpty {
            return applyingSizeLimit(to: .text, sizeBytes: sizeBytes)
        }
        return .binary
    }

    static func classifyContent(prefix: Data) -> FilesPanelDocumentKind? {
        classifyMagic(prefix: prefix) ?? classifyTextPrefix(prefix)
    }

    private static func classifyMagic(prefix: Data) -> FilesPanelDocumentKind? {
        if prefix.starts(with: Data("%PDF-".utf8)) { return .pdf }
        if prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) ||
            prefix.starts(with: Data([0xFF, 0xD8, 0xFF])) ||
            prefix.starts(with: Data("GIF8".utf8)) {
            return .image
        }
        if prefix.starts(with: Data("bplist".utf8)) { return .structured(.plist) }
        if prefix.contains(0) { return .binary }
        return nil
    }

    private static func classifyTextPrefix(_ prefix: Data) -> FilesPanelDocumentKind? {
        guard let source = String(data: prefix, encoding: .utf8) else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return .html }
        if trimmed.hasPrefix("<?xml") { return .structured(.xml) }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .structured(.json) }
        return nil
    }

    private static func classify(type: UTType) -> FilesPanelDocumentKind? {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .json) { return .structured(.json) }
        if type.conforms(to: .xml) { return .structured(.xml) }
        if type.conforms(to: .propertyList) { return .structured(.plist) }
        if type.conforms(to: .html) { return .html }
        if type.identifier == "net.daringfireball.markdown" { return .markdown }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return .text }
        return nil
    }

    private static func applyingSizeLimit(
        to kind: FilesPanelDocumentKind,
        sizeBytes: Int64
    ) -> FilesPanelDocumentKind {
        let limit = kind == .image ? maximumImageBytes : maximumTextBytes
        return sizeBytes <= limit ? kind : .tooLarge(limitBytes: limit)
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "jsonl", "css", "scss",
        "swift", "zig", "c", "h", "cc", "cpp", "hpp", "m", "mm", "py", "rb", "rs", "go", "js", "jsx", "ts", "tsx",
        "sh", "bash", "zsh", "fish", "nu", "sql", "ini", "conf", "cfg", "env", "gitignore", "dockerfile", "makefile",
    ]
    private static let structuredExtensions: [String: FilesPanelStructuredDocument.Format] = [
        "json": .json, "yaml": .yaml, "yml": .yaml, "toml": .toml, "xml": .xml, "plist": .plist,
    ]
    private static let knownExtensions =
        markdownExtensions
        .union(imageExtensions)
        .union(textExtensions)
        .union(structuredExtensions.keys)
        .union(["pdf", "html", "htm"])
}
