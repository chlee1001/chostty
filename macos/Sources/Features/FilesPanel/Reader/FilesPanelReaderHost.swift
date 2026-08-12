import SwiftUI

struct FilesPanelReaderHost: View {
    @ObservedObject var store: TerminalReaderStore
    private let markdownRenderer: any MarkdownRenderer
    private let onVisibilityChange: (Bool) -> Void

    @MainActor
    init(
        store: TerminalReaderStore,
        markdownRenderer: (any MarkdownRenderer)? = nil,
        onVisibilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.markdownRenderer = markdownRenderer ?? MarkdownUIRenderer()
        self.onVisibilityChange = onVisibilityChange
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.isOpen {
                documentTabs
                Group {
                    switch store.state {
                    case .idle:
                        EmptyView()
                    case .loading(let path):
                        FilesPanelReaderOverlayView(path: path, onClose: store.hide) {
                            ProgressView("Opening…")
                        }
                    case .failed(let path, let reason):
                        FilesPanelReaderOverlayView(path: path, onClose: store.hide) {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                Text("Couldn’t Open File").font(.headline)
                                Text(reason).foregroundStyle(.secondary)
                            }
                        }
                    case .content(let content):
                        FilesPanelReaderOverlayView(path: content.sourcePath, onClose: store.hide) {
                            contentView(content)
                        }
                    }
                }
                .id(store.selectedDocumentID)
                .transition(.identity)
            }
            if let notice = store.notice {
                Text(notice)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .accessibilityIdentifier("reader-document-limit-notice")
            }
        }
        .onAppear { onVisibilityChange(store.isOpen) }
        .onChange(of: store.isOpen, perform: onVisibilityChange)
    }

    private var documentTabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.documents) { document in
                        documentTab(document)
                    }
                }
                .padding(.leading, 8)
            }
            Menu {
                ForEach(store.documents) { document in
                    // The overflow menu is the keyboard- and VoiceOver-reachable
                    // path to every tab, so it has to offer close as well as
                    // select once the scroller runs out of width.
                    Menu(URL(fileURLWithPath: document.path).lastPathComponent) {
                        Button(document.id == store.selectedDocumentID ? "Selected" : "Select") {
                            store.select(id: document.id)
                        }
                        .disabled(document.id == store.selectedDocumentID)
                        Button("Close") { store.closeDocument(id: document.id) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("All Open Documents")
            .accessibilityLabel("All Open Documents")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open Documents")
        .accessibilityAction(named: "Next Document") {
            store.selectAdjacentDocument(offset: 1)
        }
        .accessibilityAction(named: "Previous Document") {
            store.selectAdjacentDocument(offset: -1)
        }
        .accessibilityAction(named: "Close Selected Document") {
            store.closeSelectedDocument()
        }
    }

    private func documentTab(_ document: TerminalReaderStore.Document) -> some View {
        let selected = document.id == store.selectedDocumentID
        return HStack(spacing: 4) {
            Button {
                store.select(id: document.id)
            } label: {
                Label(
                    URL(fileURLWithPath: document.path).lastPathComponent,
                    systemImage: document.isStale ? "doc.badge.clock" : iconName(for: document)
                )
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(document.path)
            .accessibilityLabel(URL(fileURLWithPath: document.path).lastPathComponent)
            .accessibilityValue(selected ? "Selected, \(document.path)" : document.path)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button {
                store.closeDocument(id: document.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Document")
            .accessibilityLabel("Close \(URL(fileURLWithPath: document.path).lastPathComponent)")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-document-tab-\(document.path)")
    }

    private func iconName(for document: TerminalReaderStore.Document) -> String {
        switch document.state {
        case .idle: "doc"
        case .loading: "hourglass"
        case .failed: "exclamationmark.triangle"
        case .content(let content):
            switch content {
            case .markdown: "doc.richtext"
            case .text: "chevron.left.forwardslash.chevron.right"
            case .structured: "list.bullet.indent"
            case .html: "globe"
            case .image: "photo"
            case .unsupported: "doc.questionmark"
            }
        }
    }

    @ViewBuilder
    private func contentView(_ content: TerminalReaderStore.Content) -> some View {
        switch content {
        case .markdown(let document):
            FilesPanelMarkdownReaderView(document: document, renderer: markdownRenderer)
        case .text(let document):
            FilesPanelTextReaderView(
                document: document,
                wrapsLines: selectedBinding(\.wrapsLines, default: false),
                searchQuery: selectedBinding(\.searchQuery, default: ""),
                scrollLine: selectedBinding(\.scrollLine, default: 0)
            )
        case .structured(let document):
            FilesPanelStructuredReaderView(
                document: document,
                showsStructure: selectedBinding(\.showsStructure, default: true),
                wrapsLines: selectedBinding(\.wrapsLines, default: false),
                searchQuery: selectedBinding(\.searchQuery, default: ""),
                scrollLine: selectedBinding(\.scrollLine, default: 0),
                expandedNodes: selectedBinding(\.expandedNodes, default: [])
            )
        case .html(let document):
            FilesPanelHTMLReaderView(
                document: document,
                showsPreview: selectedBinding(\.showsHTMLPreview, default: true),
                wrapsLines: selectedBinding(\.wrapsLines, default: false),
                searchQuery: selectedBinding(\.searchQuery, default: ""),
                scrollLine: selectedBinding(\.scrollLine, default: 0)
            )
        case .image(let document):
            FilesPanelImageReaderView(
                document: document,
                mode: selectedBinding(\.imageScaleMode, default: .fit),
                zoom: selectedBinding(\.imageZoom, default: 1)
            )
        case .unsupported(let path, let kind, let sizeBytes):
            FilesPanelUnsupportedReaderView(
                path: path,
                kind: kind,
                sizeBytes: sizeBytes
            )
        }
    }

    private func selectedBinding<Value>(
        _ keyPath: WritableKeyPath<TerminalReaderStore.ViewState, Value>,
        default defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let id = store.selectedDocumentID else { return defaultValue }
                return store.viewState(for: id, keyPath, default: defaultValue)
            },
            set: { value in
                guard let id = store.selectedDocumentID else { return }
                store.updateViewState(for: id, keyPath, to: value)
            }
        )
    }
}
