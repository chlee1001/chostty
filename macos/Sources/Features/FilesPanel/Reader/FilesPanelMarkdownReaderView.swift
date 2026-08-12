import SwiftUI

struct FilesPanelMarkdownHeading: Identifiable, Equatable, Sendable {
    let id: Int
    let level: Int
    let title: String
    let source: String
}

/// Splits Markdown into heading-anchored sections so the Reader can offer
/// document navigation, which MarkdownUI does not expose anchors for.
///
/// Sections are rendered as independent Markdown documents, so every link
/// reference definition is replayed into each section; otherwise a definition
/// declared at the end of the file would stop resolving for earlier sections.
struct FilesPanelMarkdownOutline: Equatable, Sendable {
    let preamble: String
    let sections: [FilesPanelMarkdownHeading]

    static func parse(_ source: String) -> Self {
        var preambleLines: [String] = []
        var rawSections: [(level: Int, title: String, lines: [String])] = []
        var currentLines: [String] = []
        var currentHeading: (level: Int, title: String)?
        var linkDefinitions: [String] = []
        var inFence = false

        func flush() {
            if let heading = currentHeading {
                rawSections.append((heading.level, heading.title, currentLines))
            } else {
                preambleLines.append(contentsOf: currentLines)
            }
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            }
            if !inFence {
                if isLinkDefinition(trimmed) {
                    linkDefinitions.append(trimmed)
                }
                if let heading = heading(in: trimmed) {
                    flush()
                    currentLines = [line]
                    currentHeading = heading
                    continue
                }
            }
            currentLines.append(line)
        }
        flush()

        let definitions = linkDefinitions.isEmpty ? "" : "\n\n" + linkDefinitions.joined(separator: "\n")
        let preamble = preambleLines.joined(separator: "\n")
        return .init(
            preamble: preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? preamble
                : preamble + definitions,
            sections: rawSections.enumerated().map { index, section in
                .init(
                    id: index,
                    level: section.level,
                    title: section.title,
                    source: section.lines.joined(separator: "\n") + definitions
                )
            }
        )
    }

    private static func heading(in trimmed: String) -> (level: Int, title: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " else { return nil }
        let title = trimmed.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (hashes.count, title)
    }

    private static func isLinkDefinition(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return false }
        let afterClose = trimmed.index(after: close)
        guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return false }
        return !trimmed[trimmed.index(after: afterClose)...]
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }
}

struct FilesPanelMarkdownReaderView: View {
    let document: FilesPanelMarkdownDocument
    let renderer: any MarkdownRenderer
    private let outline: FilesPanelMarkdownOutline

    init(document: FilesPanelMarkdownDocument, renderer: any MarkdownRenderer) {
        self.document = document
        self.renderer = renderer
        self.outline = .parse(document.source)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !outline.sections.isEmpty {
                    HStack {
                        Menu {
                            ForEach(outline.sections) { section in
                                Button(section.title) {
                                    proxy.scrollTo(section.id, anchor: .top)
                                }
                                .accessibilityLabel("Level \(section.level), \(section.title)")
                            }
                        } label: {
                            Label("Contents", systemImage: "list.bullet.indent")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    Divider()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !outline.preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            renderer.render(.init(sourcePath: document.sourcePath, source: outline.preamble))
                        }
                        ForEach(outline.sections) { section in
                            renderer.render(.init(sourcePath: document.sourcePath, source: section.source))
                                .id(section.id)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
}
