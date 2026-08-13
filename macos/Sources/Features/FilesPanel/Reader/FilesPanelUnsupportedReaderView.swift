import SwiftUI

struct FilesPanelUnsupportedReaderView: View {
    let path: String
    let kind: String
    let sizeBytes: Int64

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(kind, systemImage: "doc.questionmark")
                Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open in Default App") { FilesPanelFileActions.openInDefaultApp(path: path) }
            }
            .padding(8)
            Divider()
            FilesPanelQuickLookView(url: URL(fileURLWithPath: path))
        }
    }
}
