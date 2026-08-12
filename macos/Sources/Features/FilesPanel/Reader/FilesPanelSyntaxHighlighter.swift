import Foundation
import Highlighter

actor FilesPanelSyntaxHighlighter {
    static let shared = FilesPanelSyntaxHighlighter()

    private let highlighter = Highlighter()

    func highlightLines(_ source: String, language: String?) -> [AttributedString]? {
        guard let highlighted = highlighter?.highlight(source, as: language) else { return nil }
        let string = highlighted.string
        var lines: [AttributedString] = []
        string.enumerateSubstrings(
            in: string.startIndex..<string.endIndex,
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            let nsRange = NSRange(range, in: string)
            lines.append(AttributedString(highlighted.attributedSubstring(from: nsRange)))
        }
        if source.hasSuffix("\n") { lines.append(AttributedString("")) }
        return lines
    }
}
