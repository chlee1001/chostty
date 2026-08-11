import AppKit
import GhosttyKit

@MainActor
enum FilesPanelFileActions {
    static func openInDefaultApp(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copyAbsolutePath(_ path: String) {
        copy(path)
    }

    static func copyRelativePath(_ path: String, root: String) {
        copy(FilesPanelPathFormatting.relativePath(path, to: root) ?? path)
    }

    static func pasteShellEscapedPath(_ path: String, into controller: TerminalController) {
        controller.focusedSurface?.surfaceModel?.sendText(Ghostty.Shell.escape(path))
    }

    @discardableResult
    static func openNewVirtualTab(
        at path: String,
        isDirectory: Bool,
        from controller: TerminalController
    ) -> TerminalController? {
        guard let router = (NSApp.delegate as? AppDelegate)?.terminalCommands else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = isDirectory
            ? path
            : URL(fileURLWithPath: path).deletingLastPathComponent().path
        return router.createVirtualTab(source: controller.focusedSurface, baseConfig: config)
    }

    private static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
