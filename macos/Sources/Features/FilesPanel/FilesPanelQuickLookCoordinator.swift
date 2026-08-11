import AppKit
@preconcurrency import Quartz

@MainActor
final class FilesPanelQuickLookCoordinator: NSObject, ObservableObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @Published private(set) var previewURL: URL?

    func toggleSpaceAction(url: URL? = nil) {
        if let url { previewURL = url }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            endPreviewPanelControl(panel)
        } else if previewURL != nil {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (previewURL ?? URL(fileURLWithPath: "/")) as NSURL }
    }
}
