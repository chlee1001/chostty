import AppKit
import SwiftUI

struct FilesPanelImageReaderView: View {
    let document: FilesPanelImageDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: NSImage(cgImage: document.image, size: .zero))
                .resizable()
                .scaledToFit()
                .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
