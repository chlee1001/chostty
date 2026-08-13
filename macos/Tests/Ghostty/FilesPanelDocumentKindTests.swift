import Foundation
import Testing
@testable import Ghostty

struct FilesPanelDocumentKindTests {
    @Test func classifiesStructuredAndHTMLDocuments() {
        #expect(FilesPanelDocumentKind.classify(path: "/tmp/a.json", sizeBytes: 1) == .structured(.json))
        #expect(FilesPanelDocumentKind.classify(path: "/tmp/a.yaml", sizeBytes: 1) == .structured(.yaml))
        #expect(FilesPanelDocumentKind.classify(path: "/tmp/a.toml", sizeBytes: 1) == .structured(.toml))
        #expect(FilesPanelDocumentKind.classify(path: "/tmp/a.xml", sizeBytes: 1) == .structured(.xml))
        #expect(FilesPanelDocumentKind.classify(path: "/tmp/a.plist", sizeBytes: 1) == .structured(.plist))
        #expect(FilesPanelDocumentKind.classify(path: "/tmp/a.html", sizeBytes: 1) == .html)
    }

    @Test func classifiesKnownExtensionsAndMagicBytes() {
        #expect(FilesPanelDocumentKind.classify(path: "README.md", sizeBytes: 10) == .markdown)
        #expect(FilesPanelDocumentKind.classify(path: "icon.png", sizeBytes: 10) == .image)
        #expect(FilesPanelDocumentKind.classify(path: "manual.pdf", sizeBytes: 10) == .pdf)
        #expect(FilesPanelDocumentKind.classifyContent(prefix: Data("%PDF-1.7".utf8)) == .pdf)
        #expect(FilesPanelDocumentKind.classifyContent(prefix: Data([0, 1, 2])) == .binary)
    }

    @Test func strongSignaturesOverrideMisleadingExtensions() {
        #expect(FilesPanelDocumentKind.classify(
            path: "not-really.txt",
            sizeBytes: 8,
            prefix: Data("%PDF-1.7".utf8)
        ) == .pdf)
        #expect(FilesPanelDocumentKind.classify(
            path: "document",
            sizeBytes: 8,
            prefix: Data(#"{"ok":1}"#.utf8)
        ) == .structured(.json))
        #expect(FilesPanelDocumentKind.classify(
            path: "settings",
            sizeBytes: 8,
            prefix: Data("bplist00".utf8)
        ) == .structured(.plist))
    }

    @Test func appliesPerKindSizeLimits() {
        #expect(FilesPanelDocumentKind.classify(
            path: "large.txt",
            sizeBytes: FilesPanelDocumentKind.maximumTextBytes + 1
        ) == .tooLarge(limitBytes: FilesPanelDocumentKind.maximumTextBytes))
        #expect(FilesPanelDocumentKind.classify(
            path: "large.png",
            sizeBytes: FilesPanelDocumentKind.maximumImageBytes + 1
        ) == .tooLarge(limitBytes: FilesPanelDocumentKind.maximumImageBytes))
    }
}
