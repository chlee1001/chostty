import SwiftUI

struct FilesPanelTextReaderView: View {
    let document: FilesPanelTextDocument
    @State private var wrapsLines = false
    @State private var searchQuery = ""
    @State private var selectedMatch = 0

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
                    Text(String(line).isEmpty ? " " : String(line))
                        .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
                        .textSelection(.enabled)
                }
                .id(index)
                .background(highlightedLine == index ? Color.accentColor.opacity(0.18) : Color.clear)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 8)
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
