import Foundation
import GhosttyKit

/// A value-type address identifying where a surface lives in the physical → workspace →
/// tab → surface hierarchy. Carries no reference to any object.
///
/// Declared outside `SurfaceOwnerRegistry` so it is not implicitly `@MainActor`-isolated,
/// which ensures `Equatable` and `Hashable` synthesis work in all contexts.
struct SurfaceOwnerLocation: Equatable, Hashable {
    /// `ObjectIdentifier` of the owning `TerminalController`. Does not retain it.
    let controllerID: ObjectIdentifier
    /// UUID of the workspace that contains the tab owning this surface.
    let workspaceID: UUID
    /// UUID of the tab (session) that owns this surface.
    let tabID: UUID
    /// UUID of the surface itself.
    let surfaceID: UUID
}

/// A weak, `@MainActor` registry mapping live surface UUIDs to the ordinary controller
/// that owns them.
///
/// The registry is the single source of truth for "which ordinary controller
/// owns this surface." Entries are value types (`SurfaceOwnerLocation`) that identify a
/// controller by `ObjectIdentifier` — they **never** retain the controller, session,
/// surface, lease, or transfer record. Quick Terminal is never registered here; it is
/// resolved separately.
///
/// Detached surface IDs (e.g. surfaces held by a close lease) are tracked separately in
/// `detachedSurfaceIDs` so they are unavailable to live lookup and can be asserted against
/// for duplicate-registration detection.
@MainActor
final class SurfaceOwnerRegistry {
    typealias Location = SurfaceOwnerLocation

    /// Live surface UUID → location index.
    private var surfaceToLocation: [UUID: Location] = [:]

    /// Surface UUIDs currently reserved as detached (owned by a close/transfer lease).
    /// These are unavailable to live lookup and reserved for duplicate assertions.
    private var detachedSurfaceIDs: Set<UUID> = []

    // MARK: - Registration

    /// Registers a single surface location.
    ///
    /// Called after normalized store creation and selected mount but before presentation.
    func register(_ location: Location) {
        surfaceToLocation[location.surfaceID] = location
    }

    /// Atomically replaces every location belonging to `controllerID` with the supplied set.
    ///
    /// Every tree/store transaction commits its UUID index and synchronously replaces the
    /// registry index before publication. This removes all stale entries for the controller
    /// and inserts the new set in one `@MainActor` transaction.
    func replaceIndex(for controllerID: ObjectIdentifier, locations: [Location]) {
        // Remove all existing entries for this controller.
        surfaceToLocation = surfaceToLocation.filter { _, loc in
            loc.controllerID != controllerID
        }
        // Insert the new set.
        for location in locations {
            surfaceToLocation[location.surfaceID] = location
        }
    }

    /// Removes every location belonging to `controllerID`.
    ///
    /// This is the **first** `windowWillClose` action so that the closing
    /// controller's surfaces immediately become unavailable to live lookup.
    func unregister(_ controllerID: ObjectIdentifier) {
        surfaceToLocation = surfaceToLocation.filter { _, loc in
            loc.controllerID != controllerID
        }
    }

    // MARK: - Lookup

    /// Returns the live location for a surface UUID, or `nil` if the surface is not in the
    /// live index or is currently reserved as detached.
    func location(forSurfaceID surfaceID: UUID) -> Location? {
        if detachedSurfaceIDs.contains(surfaceID) { return nil }
        return surfaceToLocation[surfaceID]
    }

    /// Returns the live location for a surface view by reading its `id`.
    func location(for surface: Ghostty.SurfaceView) -> Location? {
        location(forSurfaceID: surface.id)
    }

    // MARK: - Detached reservation

    /// Marks the given surface IDs as detached — unavailable to live lookup and reserved
    /// for duplicate-registration assertions.
    ///
    /// Detached surface IDs are owned exclusively by a close/transfer lease. They must not
    /// appear in the live index simultaneously.
    func reserveDetached(surfaceIDs: Set<UUID>) {
        detachedSurfaceIDs.formUnion(surfaceIDs)
    }

    /// Releases the given surface IDs from the detached reservation set.
    ///
    /// Called when a detached lease is finalized or consumed.
    func releaseDetached(surfaceIDs: Set<UUID>) {
        detachedSurfaceIDs.subtract(surfaceIDs)
    }

    // MARK: - Counts

    /// The number of surfaces currently in the live index.
    var liveSurfaceCount: Int { surfaceToLocation.count }

    /// The number of surface IDs currently reserved as detached.
    var detachedSurfaceCount: Int { detachedSurfaceIDs.count }
}
