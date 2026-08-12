import Foundation
import Testing
@testable import Ghostty

struct FilesPanelStructuredDocumentTests {
    @Test(arguments: [
        (FilesPanelStructuredDocument.Format.json, #"{"name":"reader","enabled":true}"#),
            (.yaml, "name: reader\nenabled: true\n"),
            (.toml, "name = \"reader\"\nenabled = true\n"),
            (.xml, "<reader enabled=\"true\"><name>reader</name></reader>"),
        (.plist, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>name</key><string>reader</string></dict></plist>"),
    ])
    func parsesSupportedTextFormatsIntoOneTree(
        format: FilesPanelStructuredDocument.Format,
        source: String
    ) throws {
            let document = try FilesPanelStructuredDocument.parse(
                path: "/tmp/fixture.\(format.rawValue)",
                data: Data(source.utf8),
                format: format
            )
            #expect(document.format == format)
            #expect(document.nodeCount > 1)
    }

    @Test func parsesBinaryPropertyList() throws {
        let value = ["name": "reader", "count": 2] as [String: Any]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let document = try FilesPanelStructuredDocument.parse(path: "/tmp/a.plist", data: data, format: .plist)
        #expect(document.source == nil)
        #expect(document.nodeCount >= 3)
    }

    @Test func rejectsExcessiveXMLDepth() {
        let depth = FilesPanelStructuredDocument.maximumDepth + 1
        let source = String(repeating: "<x>", count: depth) + String(repeating: "</x>", count: depth)
        #expect(throws: (any Error).self) {
            try FilesPanelStructuredDocument.parse(path: "/tmp/deep.xml", data: Data(source.utf8), format: .xml)
        }
    }

    @Test func malformedInputThrowsWithoutLosingLoaderSourceFallback() {
        #expect(throws: (any Error).self) {
            try FilesPanelStructuredDocument.parse(path: "/tmp/a.json", data: Data("{".utf8), format: .json)
        }
    }
}
