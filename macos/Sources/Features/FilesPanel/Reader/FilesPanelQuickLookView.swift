import Quartz
import SwiftUI

struct FilesPanelQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Quick Look is unavailable for this file.")
        }
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? QLPreviewView else { return }
        let currentURL = (view.previewItem as? NSURL) as URL?
        guard currentURL != url else { return }
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? QLPreviewView else { return }
        view.previewItem = nil
        view.shouldCloseWithWindow = false
    }
}
