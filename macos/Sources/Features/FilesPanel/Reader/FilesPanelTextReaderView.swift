import SwiftUI

struct FilesPanelTextReaderView: View {
    let document: FilesPanelTextDocument
    @Binding private var wrapsLines: Bool
    @Binding private var searchQuery: String
    @Binding private var scrollLine: Int
    @State private var selectedMatch = 0
    @State private var highlightedLines: [AttributedString]?
    @State private var visibleLines: Set<Int> = []

    init(
        document: FilesPanelTextDocument,
        wrapsLines: Binding<Bool> = .constant(false),
        searchQuery: Binding<String> = .constant(""),
        scrollLine: Binding<Int> = .constant(0)
    ) {
        self.document = document
        self._wrapsLines = wrapsLines
        self._searchQuery = searchQuery
        self._scrollLine = scrollLine
    }

    static func matchingLineIndices(
        in document: FilesPanelTextDocument,
        query: String
    ) -> [Int] {
        guard !query.isEmpty else { return [] }
        return document.lines.enumerated().compactMap { index, line in
            String(line).localizedCaseInsensitiveContains(query) ? index : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Find", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(nextMatch)
                if !searchQuery.isEmpty {
                    Text(matchSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button(action: previousMatch) {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(matchingLines.isEmpty)
                    Button(action: nextMatch) {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(matchingLines.isEmpty)
                }
                Spacer()
                Toggle("Wrap", isOn: $wrapsLines)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 32)
            Divider()
            if wrapsLines {
                verticalReader
            } else {
                scrollableReader(axes: [.horizontal, .vertical], fixedWidth: true)
            }
        }
        .task(id: document.text) {
            highlightedLines = nil
            highlightedLines = await FilesPanelSyntaxHighlighter.shared.highlightLines(
                document.text,
                language: Self.language(for: document.sourcePath)
            )
        }
    }

    private var verticalReader: some View {
        scrollableReader(axes: .vertical, fixedWidth: false)
    }

    private func scrollableReader(axes: Axis.Set, fixedWidth: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(axes) {
                lineRows
                    .fixedSize(horizontal: fixedWidth, vertical: false)
                    .frame(maxWidth: fixedWidth ? nil : .infinity, alignment: .leading)
            }
            .onChange(of: selectedMatch) { _ in scrollToCurrentMatch(proxy) }
            .onChange(of: searchQuery) { _ in
                selectedMatch = 0
                scrollToCurrentMatch(proxy)
            }
            // Restoring the top visible line is what makes a document tab keep
            // its reading position across tab switches and live reloads.
            .onChange(of: visibleLines.min()) { line in
                guard let line else { return }
                scrollLine = line
            }
            .onAppear {
                guard scrollLine > 0, document.lines.indices.contains(scrollLine) else { return }
                proxy.scrollTo(scrollLine, anchor: .top)
            }
        }
    }

    private var lineRows: some View {
        let highlightedLine = currentMatchedLine
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(document.lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .trailing)
                        .textSelection(.disabled)
                    Text(displayLine(index: index, line: line))
                        .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
                        .textSelection(.enabled)
                }
                .id(index)
                .onAppear { visibleLines.insert(index) }
                .onDisappear { visibleLines.remove(index) }
                .background(highlightedLine == index ? Color.accentColor.opacity(0.18) : Color.clear)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 8)
    }

    private func displayLine(index: Int, line: Substring) -> AttributedString {
        if let highlightedLines, highlightedLines.indices.contains(index) {
            return highlightedLines[index].characters.isEmpty ? AttributedString(" ") : highlightedLines[index]
        }
        return AttributedString(String(line).isEmpty ? " " : String(line))
    }

    private static func language(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        switch url.lastPathComponent.lowercased() {
        case "dockerfile": return "dockerfile"
        case "makefile": return "makefile"
        default: return nil
        }
    }
}

private extension FilesPanelTextReaderView {
    var matchingLines: [Int] {
        Self.matchingLineIndices(in: document, query: searchQuery)
    }

    var currentMatchedLine: Int? {
        guard matchingLines.indices.contains(selectedMatch) else { return nil }
        return matchingLines[selectedMatch]
    }

    var matchSummary: String {
        matchingLines.isEmpty ? "0 matches" : "\(selectedMatch + 1) of \(matchingLines.count)"
    }

    func nextMatch() {
        guard !matchingLines.isEmpty else { return }
        selectedMatch = (selectedMatch + 1) % matchingLines.count
    }

    func previousMatch() {
        guard !matchingLines.isEmpty else { return }
        selectedMatch = (selectedMatch - 1 + matchingLines.count) % matchingLines.count
    }

    func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let line = currentMatchedLine else { return }
        proxy.scrollTo(line, anchor: .center)
    }
}
