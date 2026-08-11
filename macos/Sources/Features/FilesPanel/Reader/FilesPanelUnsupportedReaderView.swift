import SwiftUI

struct FilesPanelUnsupportedReaderView: View {
    let path: String
    let kind: String
    let sizeBytes: Int64
    let onQuickLook: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label(kind, systemImage: "doc.questionmark")
                .font(.title2)
            Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                .foregroundStyle(.secondary)
            HStack {
                Button("Preview with Quick Look", action: onQuickLook)
                Button("Open in Default App") { FilesPanelFileActions.openInDefaultApp(path: path) }
            }
        }
    }
}
