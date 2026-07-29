import AppKit
import Foundation
import GhosttyKit

/// Registry-backed resolution of a source surface to its owning ordinary
/// controller.
///
/// This is the single place that answers "which ordinary `TerminalController`
/// owns this surface", and it is what lets a command act on the correct
/// controller even when the source surface belongs to an inactive (non-
/// presented) virtual tab, where `surface.window` is nil.
///
/// Scope note: this type resolves ownership; it does **not** yet own
/// notification observation. Controllers still register their own
/// `object: nil` observers, so a source-bearing notification is still
/// delivered to every controller and filtered locally. Collapsing those into a
/// single app-level consumer is the remaining part of that work and is not
/// implemented here — do not read this type as proof that it is.
///
/// Quick Terminal is deliberately not registered here and is resolved
/// separately; this type never lazily creates it.
@MainActor
final class SurfaceEventDispatcher {
    weak var registry: SurfaceOwnerRegistry?

    /// Resolves the ordinary controller that owns the source surface.
    /// Returns nil for unregistered, detached, or Quick-owned surfaces.
    func controller(for source: Ghostty.SurfaceView) -> TerminalController? {
        guard let registry,
              let location = registry.location(forSurfaceID: source.id) else {
            // Fallback: check if the surface's current window belongs to a TerminalController.
            return source.window?.windowController as? TerminalController
        }

        for window in NSApplication.shared.windows {
            if let controller = window.windowController as? TerminalController,
               ObjectIdentifier(controller) == location.controllerID {
                return controller
            }
        }
        return nil
    }
}
