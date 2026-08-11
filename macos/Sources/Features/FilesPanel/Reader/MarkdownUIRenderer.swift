import ImageIO
import MarkdownUI
import SwiftUI

struct MarkdownUIRenderer: MarkdownRenderer {
    @MainActor
    func render(_ document: FilesPanelMarkdownDocument) -> AnyView {
        AnyView(
            Markdown(document.source, baseURL: document.baseURL, imageBaseURL: document.baseURL)
                .markdownImageProvider(FilesPanelMarkdownImageProvider())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
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
