import AppKit
import Combine
import Foundation
import Testing
@testable import Ghostty

/// Tests for the foundational workspace model types:
/// `TerminalSessionState`, `SurfaceOwnerRegistry`, and `TerminalCommandRouter`.
///
/// These tests exercise the pure-model behavior that does not require a live
/// `ghostty_app_t` / running AppDelegate. Surface-creation initializers and live
/// controller resolution are validated in integration tests once the app is running.

// MARK: - TerminalSessionState

struct TerminalSessionStateTests {
    @Test func initWithExistingTreeSetsDefaults() {
        let id = UUID()
        let tree = SplitTree<Ghostty.SurfaceView>()
        let state = TerminalSessionState(id: id, surfaceTree: tree)

        #expect(state.id == id)
        #expect(state.surfaceTree.isEmpty)
        #expect(state.focusedSurfaceID == nil)
        #expect(state.rememberedSurfaceID == nil)
        #expect(state.pwd == nil)
        #expect(state.bell == false)
        #expect(state.progress == nil)
        #expect(state.tabColor == nil)
        #expect(state.titleOverride == nil)
        #expect(state.isRestorationEligible == false)
        #expect(state.isTornDown == false)
        #expect(state.metadataGeneration == 0)
    }

    @Test func defaultTitleIsGhostEmoji() {
        let state = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )
        #expect(state.title == "👻")
    }

    @Test func tearDownIsIdempotent() {
        let state = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )

        // First teardown: state changes.
        state.tearDown()
        #expect(state.isTornDown == true)
        #expect(state.surfaceTree.isEmpty)
        #expect(state.focusedSurfaceID == nil)
        #expect(state.rememberedSurfaceID == nil)

        // Second teardown: no-op, no crash, state unchanged.
        state.tearDown()
        #expect(state.isTornDown == true)
    }

    @Test func bumpMetadataGenerationIncrements() {
        let state = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )

        #expect(state.metadataGeneration == 0)
        state.bumpMetadataGeneration()
        #expect(state.metadataGeneration == 1)
        state.bumpMetadataGeneration()
        state.bumpMetadataGeneration()
        #expect(state.metadataGeneration == 3)
    }

    @Test func publishedPropertiesAreMutable() {
        let state = TerminalSessionState(
            id: UUID(),
            surfaceTree: SplitTree<Ghostty.SurfaceView>()
        )

        state.title = "my session"
        state.pwd = "/usr/local"
        state.bell = true
        state.progress = 42
        state.tabColor = "#ff0000"
        state.titleOverride = "Custom"
        state.focusedSurfaceID = UUID()
        state.rememberedSurfaceID = UUID()

        #expect(state.title == "my session")
        #expect(state.pwd == "/usr/local")
        #expect(state.bell == true)
        #expect(state.progress == 42)
        #expect(state.tabColor == "#ff0000")
        #expect(state.titleOverride == "Custom")
        #expect(state.isRestorationEligible == false)
        #expect(state.focusedSurfaceID != nil)
        #expect(state.rememberedSurfaceID != nil)
    }
}

// MARK: - SurfaceOwnerRegistry

@MainActor
struct SurfaceOwnerRegistryTests {
    /// Holds strong references to NSObject instances so their ObjectIdentifiers
    /// remain stable (prevents address reuse after deallocation).
    private let controllerHolderA = NSObject()
    private let controllerHolderB = NSObject()

    private var controllerIDA: ObjectIdentifier { ObjectIdentifier(controllerHolderA) }
    private var controllerIDB: ObjectIdentifier { ObjectIdentifier(controllerHolderB) }

    private func makeLocation(
        controllerID: ObjectIdentifier,
        workspaceID: UUID = UUID(),
        tabID: UUID = UUID(),
        surfaceID: UUID = UUID()
    ) -> SurfaceOwnerRegistry.Location {
        .init(
            controllerID: controllerID,
            workspaceID: workspaceID,
            tabID: tabID,
            surfaceID: surfaceID
        )
    }

    @Test func registerAndLookupBySurfaceID() {
        let registry = SurfaceOwnerRegistry()
        let surfaceID = UUID()
        let location = makeLocation(controllerID: controllerIDA, surfaceID: surfaceID)

        registry.register(location)

        #expect(registry.location(forSurfaceID: surfaceID) == location)
        #expect(registry.liveSurfaceCount == 1)
    }

    @Test func lookupMissReturnsNil() {
        let registry = SurfaceOwnerRegistry()
        #expect(registry.location(forSurfaceID: UUID()) == nil)
        #expect(registry.liveSurfaceCount == 0)
    }

    @Test func replaceIndexRemovesOldAndAddsNew() {
        let registry = SurfaceOwnerRegistry()
        let controllerID = controllerIDA
        let oldSurface = UUID()
        let keptSurface = UUID()

        // Register two locations for the same controller.
        registry.register(makeLocation(controllerID: controllerID, surfaceID: oldSurface))
        registry.register(makeLocation(controllerID: controllerID, surfaceID: keptSurface))
        #expect(registry.liveSurfaceCount == 2)

        // Replace with only the kept surface plus a new one.
        let newSurface = UUID()
        registry.replaceIndex(
            for: controllerID,
            locations: [
                makeLocation(controllerID: controllerID, surfaceID: keptSurface),
                makeLocation(controllerID: controllerID, surfaceID: newSurface),
            ]
        )

        // Old surface is gone; kept + new remain.
        #expect(registry.location(forSurfaceID: oldSurface) == nil)
        #expect(registry.location(forSurfaceID: keptSurface) != nil)
        #expect(registry.location(forSurfaceID: newSurface) != nil)
        #expect(registry.liveSurfaceCount == 2)
    }

    @Test func replaceIndexDoesNotAffectOtherControllers() {
        let registry = SurfaceOwnerRegistry()
        let controllerA = controllerIDA
        let controllerB = controllerIDB
        let surfaceB = UUID()

        registry.register(makeLocation(controllerID: controllerA, surfaceID: UUID()))
        registry.register(makeLocation(controllerID: controllerB, surfaceID: surfaceB))

        registry.replaceIndex(for: controllerA, locations: [])

        // Controller B's entry survives.
        #expect(registry.location(forSurfaceID: surfaceB) != nil)
        #expect(registry.liveSurfaceCount == 1)
    }

    @Test func unregisterRemovesAllForController() {
        let registry = SurfaceOwnerRegistry()
        let controllerID = controllerIDA
        let surface1 = UUID()
        let surface2 = UUID()

        registry.register(makeLocation(controllerID: controllerID, surfaceID: surface1))
        registry.register(makeLocation(controllerID: controllerID, surfaceID: surface2))
        #expect(registry.liveSurfaceCount == 2)

        registry.unregister(controllerID)

        #expect(registry.location(forSurfaceID: surface1) == nil)
        #expect(registry.location(forSurfaceID: surface2) == nil)
        #expect(registry.liveSurfaceCount == 0)
    }

    @Test func reserveDetachedBlocksLiveLookup() {
        let registry = SurfaceOwnerRegistry()
        let surfaceID = UUID()
        let location = makeLocation(controllerID: controllerIDA, surfaceID: surfaceID)

        registry.register(location)
        #expect(registry.location(forSurfaceID: surfaceID) != nil)

        registry.reserveDetached(surfaceIDs: [surfaceID])

        // Detached surfaces are unavailable to live lookup.
        #expect(registry.location(forSurfaceID: surfaceID) == nil)
        #expect(registry.detachedSurfaceCount == 1)
        // The live index count is unaffected; detachment is a separate flag.
        #expect(registry.liveSurfaceCount == 1)
    }

    @Test func releaseDetachedRestoresLookup() {
        let registry = SurfaceOwnerRegistry()
        let surfaceID = UUID()
        let location = makeLocation(controllerID: controllerIDA, surfaceID: surfaceID)

        registry.register(location)
        registry.reserveDetached(surfaceIDs: [surfaceID])
        #expect(registry.location(forSurfaceID: surfaceID) == nil)

        registry.releaseDetached(surfaceIDs: [surfaceID])

        #expect(registry.location(forSurfaceID: surfaceID) == location)
        #expect(registry.detachedSurfaceCount == 0)
    }

    @Test func detachedCountReflectsReservations() {
        let registry = SurfaceOwnerRegistry()
        let s1 = UUID()
        let s2 = UUID()
        let s3 = UUID()

        registry.reserveDetached(surfaceIDs: [s1, s2, s3])
        #expect(registry.detachedSurfaceCount == 3)

        registry.releaseDetached(surfaceIDs: [s2])
        #expect(registry.detachedSurfaceCount == 2)

        registry.reserveDetached(surfaceIDs: [s2])
        #expect(registry.detachedSurfaceCount == 3)
    }

    @Test func locationIsEquatable() {
        let controllerID = controllerIDA
        let workspaceID = UUID()
        let tabID = UUID()
        let surfaceID = UUID()

        let a = SurfaceOwnerRegistry.Location(
            controllerID: controllerID,
            workspaceID: workspaceID,
            tabID: tabID,
            surfaceID: surfaceID
        )
        let b = SurfaceOwnerRegistry.Location(
            controllerID: controllerID,
            workspaceID: workspaceID,
            tabID: tabID,
            surfaceID: surfaceID
        )
        let c = SurfaceOwnerRegistry.Location(
            controllerID: controllerIDB,
            workspaceID: workspaceID,
            tabID: tabID,
            surfaceID: surfaceID
        )

        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - TerminalCommandRouter

@MainActor
struct TerminalCommandRouterTests {
    @Test func performReservedShortcutReturnsFalseForNonShortcut() {
        let router = TerminalCommandRouter()
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        #expect(router.performReservedShortcut(event, source: nil) == false)
    }

    @Test func performReservedShortcutReturnsFalseForPlainCmdWithoutMatch() {
        let router = TerminalCommandRouter()
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 0
        )!

        // Cmd+X is not a reserved shortcut; router should return false without
        // attempting to resolve a destination.
        #expect(router.performReservedShortcut(event, source: nil) == false)
    }

    @Test func performReservedShortcutReturnsFalseForNonKeyDown() {
        let router = TerminalCommandRouter()
        let event = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 0
        )!

        #expect(router.performReservedShortcut(event, source: nil) == false)
    }

    @Test func routerHoldsWeakDispatcherReference() {
        let router = TerminalCommandRouter()
        let dispatcher = SurfaceEventDispatcher()
        router.dispatcher = dispatcher

        #expect(router.dispatcher === dispatcher)
    }

    @Test func dispatcherHoldsWeakRegistryReference() {
        let dispatcher = SurfaceEventDispatcher()
        let registry = SurfaceOwnerRegistry()
        dispatcher.registry = registry

        #expect(dispatcher.registry === registry)
    }

}
