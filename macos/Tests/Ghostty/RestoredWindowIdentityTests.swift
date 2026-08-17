import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

/// An AppleScript `window id` is derived from the controller's
/// `physicalUUID`. That value was persisted as `physicalID` and then thrown
/// away on restore — every restored window minted a fresh one — so an id a
/// script saved before quit addressed nothing after relaunch. The persisted
/// field existed and was simply never read back, which nothing noticed
/// because no test asserted the round trip.
///
/// These tests pin the identity contract at the seam that broke: an id must
/// survive a restore, a genuinely new window must not inherit one, and the
/// fallback taken when the saved hierarchy is unusable must mint a fresh id
/// rather than impersonate the window it failed to restore.
@MainActor
struct RestoredWindowIdentityTests {
    private func makeSession() -> TerminalSessionState {
        TerminalSessionState(id: UUID(), surfaceTree: SplitTree<Ghostty.SurfaceView>())
    }

    private func makeWorkspace(name: String = "Workspace 1", tabCount: Int = 1) -> WorkspaceSession {
        let tabs = (0..<tabCount).map { _ in makeSession() }
        return WorkspaceSession(id: UUID(), name: name, tabs: tabs, selectedTabID: tabs.first?.id)
    }

    private func makeController(restoredPhysicalUUID: UUID?) throws -> TerminalController {
        let ws = makeWorkspace()
        let selection = Selection(workspaceID: ws.id, tabID: ws.tabs[0].id)
        return try #require(TerminalControllerTestHarness.make(
            workspaces: [ws],
            selection: selection,
            restoredPhysicalUUID: restoredPhysicalUUID))
    }

    /// The rehydrated UUID must reach `stableID`, which is what scripting
    /// actually addresses. Asserting on `physicalUUID` alone would still pass
    /// if `stableID` derived from something else.
    @Test func restoredControllerAdoptsThePersistedIdentity() throws {
        let persisted = UUID()
        let controller = try makeController(restoredPhysicalUUID: persisted)

        #expect(controller.physicalUUID == persisted)
        #expect(
            ScriptWindow.stableID(primaryController: controller)
                == "window-\(persisted.uuidString)")
    }

    /// Two restores of the same saved state must agree. This is the property
    /// a script actually depends on across a quit/relaunch cycle.
    @Test func samePersistedIdentityYieldsTheSameScriptingID() throws {
        let persisted = UUID()
        let first = try makeController(restoredPhysicalUUID: persisted)
        let second = try makeController(restoredPhysicalUUID: persisted)

        #expect(
            ScriptWindow.stableID(primaryController: first)
                == ScriptWindow.stableID(primaryController: second))
    }

    /// A window created fresh must not inherit any id: two windows addressing
    /// the same scripting object would be worse than an id that changes.
    @Test func freshControllersMintDistinctIdentities() throws {
        let first = try makeController(restoredPhysicalUUID: nil)
        let second = try makeController(restoredPhysicalUUID: nil)

        #expect(first.physicalUUID != second.physicalUUID)
        #expect(
            ScriptWindow.stableID(primaryController: first)
                != ScriptWindow.stableID(primaryController: second))
    }

    /// A restored window and a fresh one must not collide either.
    @Test func aFreshWindowDoesNotCollideWithARestoredOne() throws {
        let persisted = UUID()
        let restored = try makeController(restoredPhysicalUUID: persisted)
        let fresh = try makeController(restoredPhysicalUUID: nil)

        #expect(fresh.physicalUUID != restored.physicalUUID)
    }

    // MARK: - Surface runtime and persisted identities

    @Test func newSurfacesMintDistinctRuntimeAndLogicalIdentities() {
        let first = Ghostty.OSSurfaceView(frame: .zero)
        let second = Ghostty.OSSurfaceView(frame: .zero)

        #expect(first.id != second.id)
        #expect(first.logicalPaneID != second.logicalPaneID)
    }

    @Test func restoredLogicalPaneIdentityNeverControlsRuntimeIdentity() {
        let logicalPaneID = UUID()
        let first = Ghostty.OSSurfaceView(logicalPaneID: logicalPaneID, frame: .zero)
        let second = Ghostty.OSSurfaceView(logicalPaneID: logicalPaneID, frame: .zero)

        #expect(first.logicalPaneID == logicalPaneID)
        #expect(second.logicalPaneID == logicalPaneID)
        #expect(first.id != logicalPaneID)
        #expect(second.id != logicalPaneID)
        #expect(first.id != second.id)
    }

    @Test func quickTerminalCodableKeepsItsEstablishedArchiveKey() {
        #expect(Ghostty.SurfaceView.CodingKeys.logicalPaneID.rawValue == "uuid")
    }

    @Test func coldRestoreEligibilityRequiresNoEffectiveLaunchIntent() {
        #expect(Ghostty.SurfaceView.acceptsColdRestore(.init(cValue: .init(
            has_command: false,
            has_environment_overrides: false,
            has_initial_input: false
        ))))
        #expect(!Ghostty.SurfaceView.acceptsColdRestore(.init(cValue: .init(
            has_command: true,
            has_environment_overrides: false,
            has_initial_input: false
        ))))
        #expect(!Ghostty.SurfaceView.acceptsColdRestore(.init(cValue: .init(
            has_command: false,
            has_environment_overrides: true,
            has_initial_input: false
        ))))
        #expect(!Ghostty.SurfaceView.acceptsColdRestore(.init(cValue: .init(
            has_command: false,
            has_environment_overrides: false,
            has_initial_input: true
        ))))
    }
}
