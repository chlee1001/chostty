import SwiftUI

struct FilesPanelReaderOverlayView<Content: View>: View {
    let path: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Hide", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Hide Reader")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.bar)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-panel-reader-overlay")
        .onExitCommand(perform: onClose)
    }
}
