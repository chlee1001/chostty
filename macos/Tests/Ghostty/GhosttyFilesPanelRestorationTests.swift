import Foundation
import Testing
@testable import Ghostty

@MainActor
struct GhosttyFilesPanelRestorationTests {
    /// Command-line defaults (`-chostty.filesPanelVisible YES`) arrive as
    /// strings; they must seed the panel the way stored booleans do.
    @Test func seedReadsStringAndStoredDefaults() throws {
        let suite = "chostty.tests.files-panel-seed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let empty = FilesPanelPresentationState.Seed.fromDefaults(defaults)
        #expect(!empty.visible)
        #expect(empty.width == 280)
        #expect(!empty.showHidden)

        defaults.set("YES", forKey: "chostty.filesPanelVisible")
        defaults.set("320", forKey: "chostty.filesPanelWidth")
        defaults.set("YES", forKey: "chostty.filesPanelShowHidden")
        let strings = FilesPanelPresentationState.Seed.fromDefaults(defaults)
        #expect(strings.visible)
        #expect(strings.width == 320)
        #expect(strings.showHidden)

        defaults.set(false, forKey: "chostty.filesPanelVisible")
        defaults.set(336.0, forKey: "chostty.filesPanelWidth")
        let stored = FilesPanelPresentationState.Seed.fromDefaults(defaults)
        #expect(!stored.visible)
        #expect(stored.width == 336)
    }

    @Test func persistedPresentationRoundTripsWithoutTransientLayoutState() throws {
        var presentation = FilesPanelPresentationState(seed: .init(
            visible: true,
            width: 336,
            rootMode: .pinned,
            pinnedRoot: "/tmp/project",
            showHidden: true
        ))
        presentation.isAutoCollapsedByLayout = true

        let data = try JSONEncoder().encode(presentation.persisted)
        let decoded = try JSONDecoder().decode(FilesPanelPresentationState.Persisted.self, from: data)
        let restored = FilesPanelPresentationState(seed: .init(
            visible: decoded.visible,
            width: decoded.width,
            rootMode: decoded.rootMode,
            pinnedRoot: decoded.pinnedRoot,
            showHidden: decoded.showHidden
        ))

        #expect(restored.visible)
        #expect(restored.width == 336)
        #expect(restored.rootMode == .pinned)
        #expect(restored.pinnedRoot == "/tmp/project")
        #expect(restored.showHidden)
        #expect(!restored.isAutoCollapsedByLayout)
    }

    @Test func stalePinnedRootIsDetectedOffTheMainActor() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        #expect(!(await FilesPanelController.isDirectory(path: missing)))
        #expect(await FilesPanelController.isDirectory(path: FileManager.default.temporaryDirectory.path))
    }

    @Test func restoredSessionReaderStartsIdle() {
        let session = TerminalSessionState(id: UUID(), surfaceTree: .init())
        guard case .idle = session.readerStore.state else {
            Issue.record("restored reader must start idle")
            return
        }
    }

    @Test func panelControlsExposeAccessibilityAndFilterUsesTextFieldGuard() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panel = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/Features/FilesPanel/FilesPanelView.swift"),
            encoding: .utf8
        )
        let row = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/Features/FilesPanel/FilesPanelRow.swift"),
            encoding: .utf8
        )
        let overlay = try String(
            contentsOf: macosRoot.appendingPathComponent(
                "Sources/Features/FilesPanel/Reader/FilesPanelReaderOverlayView.swift"
            ),
            encoding: .utf8
        )
        let delegate = try String(
            contentsOf: macosRoot.appendingPathComponent("Sources/App/macOS/AppDelegate.swift"),
            encoding: .utf8
        )

        #expect(panel.contains("TextField(\"Filter Files\""))
        #expect(panel.contains(".accessibilityIdentifier(\"files-panel-filter\")"))
        #expect(panel.contains(".accessibilityIdentifier(\"files-panel\")"))
        #expect(row.contains(".accessibilityIdentifier(\"files-panel-row-"))
        #expect(overlay.contains(".accessibilityIdentifier(\"files-panel-reader-overlay\")"))
        #expect(delegate.contains("firstResponder is NSText"))
    }

    @Test func narrowLayoutAutoCollapseIsTransientAndDeterministic() {
        #expect(FilesPanelPresentationState.shouldAutoCollapse(
            availableWidth: 700,
            sidebarWidth: 220,
            panelWidth: 280
        ))
        #expect(!FilesPanelPresentationState.shouldAutoCollapse(
            availableWidth: 900,
            sidebarWidth: 220,
            panelWidth: 280
        ))
        #expect(!FilesPanelPresentationState.shouldAutoCollapse(
            availableWidth: 700,
            sidebarWidth: 0,
            panelWidth: 280
        ))
    }
}
