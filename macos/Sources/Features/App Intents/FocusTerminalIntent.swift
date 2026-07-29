import AppKit
import AppIntents
import GhosttyKit

struct FocusTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus Terminal"
    static var description = IntentDescription("Move focus to an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to focus.",
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
        // though the surface is perfectly live. Resolving through the
        // workspace store first (rather than `surfaceView.window`) lets this
        // intent work for every tab, not only the mounted one.
        guard let controller = NSApp.owningController(forSurfaceID: surfaceView.id),
              let address = controller.workspaceStore.address(forSurfaceID: surfaceView.id) else {
            throw GhosttyIntentError.surfaceNotFound
        }

        controller.selectSession(workspaceID: address.workspaceID, tabID: address.tabID)
        controller.focusSurface(surfaceView)
        return .result()
    }
}
