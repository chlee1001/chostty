import Foundation
import Testing
@testable import Ghostty

struct FilesPanelDocumentLoaderTests {
    @Test func loadsUTF8TextAndMarkdown() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("a.txt")
        let markdownURL = root.appendingPathComponent("a.md")
        try Data("hello".utf8).write(to: textURL)
        try Data("# hello".utf8).write(to: markdownURL)
        let loader = FilesPanelDocumentLoader()

        let text = await loader.load(path: textURL.path)
        let markdown = await loader.load(path: markdownURL.path)
        guard case .success(.text(let textDocument)) = text,
              case .success(.markdown(let markdownDocument)) = markdown else {
            Issue.record("unexpected document kinds")
            return
        }
        #expect(textDocument.text == "hello")
        #expect(markdownDocument.source == "# hello")
    }

    @Test func rejectsOversizedTextFromMetadata() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.txt")
        try Data(repeating: 0x41, count: FilesPanelDocumentKind.maximumTextBytes.intValue + 1).write(to: url)

        let result = await FilesPanelDocumentLoader().load(path: url.path)
        guard case .success(.unsupported(_, let kind, let size)) = result else {
            Issue.record("expected unsupported oversized file")
            return
        }
        #expect(kind.contains("exceeds"))
        #expect(size > FilesPanelDocumentKind.maximumTextBytes)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Int64 {
    var intValue: Int { Int(self) }
}
