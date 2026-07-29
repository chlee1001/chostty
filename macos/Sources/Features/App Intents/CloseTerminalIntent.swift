import AppKit
import AppIntents
import GhosttyKit

struct CloseTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Close Terminal"
    static var description = IntentDescription("Close an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to close.",
    )
    var terminal: TerminalEntity

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background
#endif

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let surfaceView = terminal.surfaceView else {
            throw GhosttyIntentError.surfaceNotFound
        }

        // Resolve the owning tab FIRST, mirroring
        // `BaseTerminalController.ghosttyDidPresentTerminal`: a `TerminalEntity`
        // built from `allWorkspaceSurfaces` may address a surface whose tab is
        // not currently presented, so `surfaceView.window` can be nil even
        // though the surface is perfectly live. `closeSurface` is scoped to
        // the presented tree, so the owning tab must be selected first.
        guard let controller = NSApp.owningController(forSurfaceID: surfaceView.id),
              let address = controller.workspaceStore.address(forSurfaceID: surfaceView.id) else {
            throw GhosttyIntentError.surfaceNotFound
        }

        controller.selectSession(workspaceID: address.workspaceID, tabID: address.tabID)
        controller.closeSurface(surfaceView, withConfirmation: false)
        return .result()
    }
}
