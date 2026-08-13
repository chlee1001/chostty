import SwiftUI

struct FilesPanelStructuredReaderView: View {
    let document: FilesPanelStructuredDocument
    @Binding private var showsStructure: Bool
    private let wrapsLines: Binding<Bool>
    private let searchQuery: Binding<String>
    private let scrollLine: Binding<Int>
    @Binding private var expandedNodes: Set<String>

    init(
        document: FilesPanelStructuredDocument,
        showsStructure: Binding<Bool> = .constant(true),
        wrapsLines: Binding<Bool> = .constant(false),
        searchQuery: Binding<String> = .constant(""),
        scrollLine: Binding<Int> = .constant(0),
        expandedNodes: Binding<Set<String>> = .constant([])
    ) {
        self.document = document
        self._showsStructure = showsStructure
        self.wrapsLines = wrapsLines
        self.searchQuery = searchQuery
        self.scrollLine = scrollLine
        self._expandedNodes = expandedNodes
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Document View", selection: $showsStructure) {
                Text("Structure").tag(true)
                if document.source != nil { Text("Source").tag(false) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(8)

            Divider()
            if let parseError = document.parseError {
                VStack(spacing: 12) {
                    Label("Couldn’t Parse \(document.format.rawValue.uppercased())", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(parseError)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let source = document.source {
                        FilesPanelTextReaderView(
                            document: .init(sourcePath: document.sourcePath, text: source),
                            wrapsLines: wrapsLines,
                            searchQuery: searchQuery,
                            scrollLine: scrollLine
                        )
                    }
                }
                .padding()
            } else if showsStructure, let root = document.root {
                List {
                    FilesPanelStructuredValueView(
                        path: "$",
                        label: document.format.rawValue.uppercased(),
                        value: root,
                        expandedNodes: $expandedNodes
                    )
                }
            } else if let source = document.source {
                FilesPanelTextReaderView(
                    document: .init(sourcePath: document.sourcePath, text: source),
                    wrapsLines: wrapsLines,
                    searchQuery: searchQuery,
                    scrollLine: scrollLine
                )
            }
        }
    }
}

private struct FilesPanelStructuredValueView: View {
    let path: String
    let label: String
    let value: FilesPanelStructuredValue
    @Binding var expandedNodes: Set<String>

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedNodes.contains(path) },
            set: { expanded in
                if expanded {
                    expandedNodes.insert(path)
                } else {
                    expandedNodes.remove(path)
                }
            }
        )
    }

    var body: some View {
        switch value {
        case .object(let entries):
            DisclosureGroup(label, isExpanded: isExpanded) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    FilesPanelStructuredValueView(
                        path: "\(path).\(entry.key)[\(index)]",
                        label: entry.key,
                        value: entry.value,
                        expandedNodes: $expandedNodes
                    )
                }
            }
            .id(path)
        case .array(let values):
            DisclosureGroup("\(label) [\(values.count)]", isExpanded: isExpanded) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    FilesPanelStructuredValueView(
                        path: "\(path)[\(index)]",
                        label: "[\(index)]",
                        value: value,
                        expandedNodes: $expandedNodes
                    )
                }
            }
            .id(path)
        case .string(let value): scalar(label, value, color: .primary)
        case .number(let value): scalar(label, value, color: .blue)
        case .bool(let value): scalar(label, String(value), color: .purple)
        case .null: scalar(label, "null", color: .secondary)
        }
    }

    private func scalar(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).fontWeight(.medium)
            Text(value).foregroundStyle(color).textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
    }
}
