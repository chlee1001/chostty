import Testing
@testable import Ghostty

struct FilesPanelTextDocumentTests {
    @Test func preservesEmptyLinesAndReportsUTF8Cost() {
        let document = FilesPanelTextDocument(sourcePath: "/tmp/a", text: "a\n\n한글")
        #expect(document.lines.map(String.init) == ["a", "", "한글"])
        #expect(document.estimatedByteCost == document.text.utf8.count)
    }

    @Test func fileSearchFindsCaseInsensitiveLineIndices() {
        let document = FilesPanelTextDocument(
            sourcePath: "/tmp/a",
            text: "alpha\nReader\nbeta reader\nomega"
        )

        #expect(FilesPanelTextReaderView.matchingLineIndices(
            in: document,
            query: "reader"
        ) == [1, 2])
        #expect(FilesPanelTextReaderView.matchingLineIndices(
            in: document,
            query: ""
        ).isEmpty)
    }
}
