import ImageIO
import MarkdownUI
import SwiftUI

struct MarkdownUIRenderer: MarkdownRenderer {
    @MainActor
    func render(_ document: FilesPanelMarkdownDocument) -> AnyView {
        AnyView(
            Markdown(document.source, baseURL: document.baseURL, imageBaseURL: document.baseURL)
                .markdownImageProvider(FilesPanelMarkdownImageProvider())
                .markdownBlockStyle(\.codeBlock) { configuration in
                    FilesPanelHighlightedCodeBlock(
                        source: configuration.content,
                        language: configuration.language
                    )
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}

private struct FilesPanelHighlightedCodeBlock: View {
    let source: String
    let language: String?
    @State private var lines: [AttributedString]?

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array((lines ?? [AttributedString(source)]).enumerated()), id: \.offset) { _, line in
                    Text(line.characters.isEmpty ? AttributedString(" ") : line)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
        }
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: source) {
            lines = await FilesPanelSyntaxHighlighter.shared.highlightLines(source, language: language)
        }
    }
}

private struct FilesPanelMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        FilesPanelMarkdownImage(url: url)
    }
}

private struct FilesPanelMarkdownImage: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
        }
    }
}
