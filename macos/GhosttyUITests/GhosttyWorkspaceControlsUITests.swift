import XCTest

/// The workspace controls (sidebar toggle, actions menu) must be reachable
/// in every window state, in both sidebar states.
///
/// Existence alone is not enough: each test also pins whether the sidebar is
/// open and which host the button came from.
final class GhosttyWorkspaceControlsUITests: GhosttyCustomConfigCase {
    /// `GhosttyCustomConfigCase` skips itself outside the Xcode IDE, so its
    /// subclasses never run under a plain `xcodebuild test`. This suite opts
    /// back in — it is a handful of launches, and no unit test can see where
    /// these buttons actually render.
    override class var defaultTestSuite: XCTestSuite {
        XCTestSuite(forTestCaseClass: Self.self)
    }

    /// Titlebar band: a standard macOS titlebar is 28pt, so anything whose top
    /// edge is within 32pt of the window's is in it rather than in the content.
    private static let titlebarBand: CGFloat = 32

    /// `-key value` launch arguments land in `NSArgumentDomain`, which outranks
    /// the persisted domain and is never written back, so the sidebar state
    /// under test cannot leak into the developer's own preferences.
    @MainActor
    private func launch(config: String, sidebarVisible: Bool) throws -> XCUIApplication {
        try updateConfig(config)
        let app = try ghosttyApplication()
        app.launchArguments.append(contentsOf: [
            "-chostty.sidebarVisible", sidebarVisible ? "YES" : "NO",
        ])
        app.launch()
        return app
    }

    @MainActor
    private func window(of app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        return window
    }

    // MARK: Titlebar accessory

    @MainActor
    func testControlsRenderInTheTitlebarRightOfTheTrafficLights() throws {
        let app = try launch(config: "macos-titlebar-style = transparent", sidebarVisible: true)
        let window = window(of: app)

        let toggle = window.buttons["Hide Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "sidebar toggle is missing entirely")
        let actions = window.buttons["Workspace Actions"]
        XCTAssertTrue(actions.exists, "workspace actions menu is missing")

        // The sidebar really is open, so this is the open-state placement.
        XCTAssertTrue(window.staticTexts["Workspaces"].exists)

        XCTAssertLessThan(
            toggle.frame.minY, window.frame.minY + Self.titlebarBand,
            "toggle is below the titlebar, so it moved back into the content")

        let close = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists)
        XCTAssertGreaterThan(
            toggle.frame.minX, close.frame.maxX,
            "toggle overlaps the traffic lights")

        // Hittability, not just existence: the first cut of the accessory
        // resolved to zero width, so the buttons were laid out and reachable by
        // accessibility while being clipped to nothing on screen.
        XCTAssertTrue(toggle.isHittable, "toggle exists but nothing can click it")
        XCTAssertTrue(window.buttons["Workspace Actions"].isHittable)
    }

    /// With the sidebar closed there has to be a button somewhere in the window.
    @MainActor
    func testControlsSurviveAClosedSidebar() throws {
        let app = try launch(config: "macos-titlebar-style = transparent", sidebarVisible: false)
        let window = window(of: app)

        let toggle = window.buttons["Show Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no way back to the sidebar")
        XCTAssertTrue(window.buttons["Workspace Actions"].exists)

        // Proves the sidebar is genuinely closed: otherwise this test would pass
        // on the old header-hosted buttons.
        XCTAssertFalse(window.staticTexts["Workspaces"].exists)

        XCTAssertLessThan(toggle.frame.minY, window.frame.minY + Self.titlebarBand)
        XCTAssertTrue(toggle.isHittable, "toggle exists but nothing can click it")
    }

    /// Clicking the titlebar toggle has to move the sidebar, in both directions.
    ///
    /// Launched without the `NSArgumentDomain` override the other tests use,
    /// since that domain outranks the write `@AppStorage` performs. Writes land
    /// in `kr.co.devch.chostty.debug`, a separate domain from the release app, and
    /// the test restores the state it found.
    @MainActor
    func testTitlebarToggleActuallyMovesTheSidebar() throws {
        try updateConfig("macos-titlebar-style = transparent")
        let app = try ghosttyApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launch()

        let window = window(of: app)
        let header = window.staticTexts["Workspaces"]
        XCTAssertTrue(
            window.buttons["Hide Sidebar"].waitForExistence(timeout: 10)
                || window.buttons["Show Sidebar"].waitForExistence(timeout: 1),
            "no toggle in the titlebar at all")

        let startedOpen = header.exists
        let openLabel = "Hide Sidebar"
        let closedLabel = "Show Sidebar"

        window.buttons[startedOpen ? openLabel : closedLabel].click()
        XCTAssertTrue(
            startedOpen
                ? header.waitForNonExistence(timeout: 5)
                : header.waitForExistence(timeout: 5),
            "toggle click did not move the sidebar")

        // Back to where we found it, and the reverse direction gets exercised.
        window.buttons[startedOpen ? closedLabel : openLabel].click()
        XCTAssertTrue(
            startedOpen
                ? header.waitForExistence(timeout: 5)
                : header.waitForNonExistence(timeout: 5),
            "toggle click did not move the sidebar back")
    }

    // MARK: In-window strip

    /// Non-native fullscreen drops `.titled`, which removes the titlebar and
    /// derefs its accessories. The absence of the traffic lights is what proves
    /// the buttons came from the in-window strip and not from the accessory.
    @MainActor
    func testControlsRenderInTheStripWhenThereIsNoTitlebar() throws {
        let app = try launch(config: """
            fullscreen = true
            macos-non-native-fullscreen = true
            """, sidebarVisible: false)
        let window = window(of: app)

        XCTAssertTrue(
            window.buttons["Show Sidebar"].waitForExistence(timeout: 10),
            "fullscreen with no sidebar left no way back")
        XCTAssertTrue(window.buttons["Workspace Actions"].exists)
        XCTAssertTrue(
            window.buttons["Show Sidebar"].isHittable,
            "strip is laid out but clipped or covered")
        XCTAssertFalse(
            window.buttons[XCUIIdentifierCloseWindow].exists,
            "window still has a titlebar, so this proves nothing about the strip")
    }

    /// Native fullscreen keeps `.titled`, so the accessory still exists — it is
    /// parked in an auto-hiding overlay. The strip has to take over and actually
    /// render, hence hittability rather than existence.
    ///
    /// Queried from the app rather than the window: entering native fullscreen
    /// moves the window to its own space and the window element stops resolving.
    @MainActor
    func testControlsRemainClickableThroughNativeFullscreen() throws {
        let app = try launch(config: "macos-titlebar-style = transparent", sidebarVisible: true)
        let window = window(of: app)
        XCTAssertTrue(window.buttons["Hide Sidebar"].waitForExistence(timeout: 10))

        // This test drives the menu bar and switches spaces, so it needs to own
        // the foreground. The suite runs parallelized and a sibling test's app
        // otherwise owns the menu bar we are about to click.
        app.activate()

        // Baseline: windowed, so the traffic lights are clickable.
        let close = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.isHittable)

        // Driven from the menu rather than ⌃⌘F, whose synthesized key event does
        // not reach the app reliably here. Native fullscreen, because
        // `macos-non-native-fullscreen` is left at its default.
        let toggleFullScreen = app.menuBars.menuItems["Toggle Full Screen"]
        XCTAssertTrue(toggleFullScreen.exists)
        toggleFullScreen.click()

        // Losing the traffic lights is how we know fullscreen actually engaged:
        // AppKit parks the whole titlebar in an auto-hiding overlay.
        var entered = false
        for _ in 0..<40 {
            if !close.exists { entered = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(entered, "never entered fullscreen, so this test proved nothing")

        // The pointer is parked on the menu bar after clicking the menu item, and
        // in native fullscreen that keeps the system titlebar revealed right on
        // top of the strip. Move it onto the sidebar first — hovering the app
        // element itself is not an option, since a fullscreen window reports an
        // unresolvable frame.
        app.staticTexts["Workspaces"].hover()

        // Behavioural check rather than a hittability probe: the actions menu
        // sits one point below the screen edge in fullscreen, and XCUITest
        // calls it not hittable even when a real click lands. Watching for the
        // workspace it creates cannot pass on an invisible or dead strip.
        let toggle = app.buttons["Hide Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no strip in native fullscreen")
        XCTAssertTrue(toggle.isHittable, "strip is laid out but nothing can click it")

        let actions = app.buttons["Workspace Actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "no strip actions menu in native fullscreen")
        actions.click()
        XCTAssertTrue(
            app.menuItems["New Workspace"].waitForExistence(timeout: 10),
            "the strip's menu did nothing in native fullscreen")
        app.menuItems["New Workspace"].click()
        XCTAssertTrue(
            app.staticTexts["Workspace 2"].waitForExistence(timeout: 10),
            "the strip's menu entry did nothing in native fullscreen")
    }

    // MARK: Sidebar header

    /// `macos-titlebar-style = hidden` removes the window chrome on purpose, so
    /// the controls stay in the sidebar header instead of reappearing as a strip
    /// that hands the chrome back. Sitting on the header row is what
    /// distinguishes this host from the other two.
    @MainActor
    func testControlsStayInTheSidebarHeaderForTheHiddenTitlebarStyle() throws {
        let app = try launch(config: "macos-titlebar-style = hidden", sidebarVisible: true)
        let window = window(of: app)

        let toggle = window.buttons["Hide Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "hidden titlebar hid the controls too")
        XCTAssertTrue(window.buttons["Workspace Actions"].exists)

        let header = window.staticTexts["Workspaces"]
        XCTAssertTrue(header.exists)
        XCTAssertEqual(
            toggle.frame.midY, header.frame.midY, accuracy: 6,
            "toggle is not on the header row, so it came from some other host")
    }
}
