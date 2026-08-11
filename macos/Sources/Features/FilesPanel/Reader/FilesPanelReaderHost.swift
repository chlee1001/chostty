import SwiftUI

struct FilesPanelReaderHost: View {
    @ObservedObject var store: TerminalReaderStore
    private let markdownRenderer: any MarkdownRenderer
    @StateObject private var quickLook = FilesPanelQuickLookCoordinator()
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
        Group {
            switch store.state {
            case .idle:
                EmptyView()
            case .loading(let path):
                FilesPanelReaderOverlayView(path: path, onClose: store.close) {
                    ProgressView("Opening…")
                }
            case .failed(let path, let reason):
                FilesPanelReaderOverlayView(path: path, onClose: store.close) {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text("Couldn’t Open File").font(.headline)
                        Text(reason).foregroundStyle(.secondary)
                    }
                }
            case .content(let content):
                FilesPanelReaderOverlayView(path: content.sourcePath, onClose: store.close) {
                    contentView(content)
                }
            }
        }
        .onAppear { onVisibilityChange(store.isOpen) }
        .onChange(of: store.isOpen, perform: onVisibilityChange)
    }

    @ViewBuilder
    private func contentView(_ content: TerminalReaderStore.Content) -> some View {
        switch content {
        case .markdown(let document):
            ScrollView {
                markdownRenderer.render(document)
                    .padding(24)
            }
        case .text(let document):
            FilesPanelTextReaderView(document: document)
        case .image(let document):
            FilesPanelImageReaderView(document: document)
        case .unsupported(let path, let kind, let sizeBytes):
            FilesPanelUnsupportedReaderView(
                path: path,
                kind: kind,
                sizeBytes: sizeBytes,
                onQuickLook: { quickLook.toggleSpaceAction(url: URL(fileURLWithPath: path)) }
            )
        }
    }
}
