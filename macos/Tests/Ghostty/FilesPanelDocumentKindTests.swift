import Foundation
import Testing
@testable import Ghostty

struct FilesPanelDocumentKindTests {
    @Test func classifiesKnownExtensionsAndMagicBytes() {
        #expect(FilesPanelDocumentKind.classify(path: "README.md", sizeBytes: 10) == .markdown)
        #expect(FilesPanelDocumentKind.classify(path: "icon.png", sizeBytes: 10) == .image)
        #expect(FilesPanelDocumentKind.classify(path: "manual.pdf", sizeBytes: 10) == .pdf)
        #expect(FilesPanelDocumentKind.classifyContent(prefix: Data("%PDF-1.7".utf8)) == .pdf)
        #expect(FilesPanelDocumentKind.classifyContent(prefix: Data([0, 1, 2])) == .binary)
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
