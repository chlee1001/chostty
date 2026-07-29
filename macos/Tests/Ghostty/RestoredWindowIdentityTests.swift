import Foundation
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

    // MARK: - The restore seam itself

    /// The invalid-hierarchy fallback in `restoreWindow` builds a plain
    /// controller and must NOT receive the persisted id: that window is a
    /// fresh workspace, not the one that failed to restore, so adopting the
    /// saved id would hand scripts a window with different contents under the
    /// id they saved.
    ///
    /// Source-pinned because driving `NSWindowRestoration` needs a real
    /// restoration cycle this test host cannot run. Comments are stripped and
    /// whitespace normalized so this matches code, not prose.
    @Test func onlyTheHierarchyPathConsumesThePersistedIdentity() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../macos/Tests/Ghostty
            .deletingLastPathComponent() // .../macos/Tests
            .deletingLastPathComponent() // .../macos
            .appendingPathComponent("Sources/Features/Terminal/TerminalRestorable.swift")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!raw.isEmpty)
        // `normalize` strips `//` but not `/* */`, so a block comment here
        // would silently weaken the assertions below.
        #expect(!raw.contains("/*"))

        let source = VirtualTabBarScrollTests.normalize(raw)

        // The hierarchy path threads it through...
        #expect(source.contains("restoredPhysicalUUID: state.physicalID"))
        // ...the fallback builds a bare controller...
        #expect(source.contains("c = TerminalController(appDelegate.ghostty)"))
        // ...and exactly one site consumes the persisted id.
        let uses = source.components(separatedBy: "restoredPhysicalUUID: state.physicalID").count - 1
        #expect(uses == 1)
    }
}
