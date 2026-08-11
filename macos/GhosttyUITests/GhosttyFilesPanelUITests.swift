import XCTest

final class GhosttyFilesPanelUITests: GhosttyCustomConfigCase {
    override class var defaultTestSuite: XCTestSuite {
        XCTestSuite(forTestCaseClass: Self.self)
    }

    @MainActor
    func testFilesPanelOpensForkMarkdownInReader() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try updateConfig("""
            macos-titlebar-style = transparent
            working-directory = \(repositoryRoot.path)
            window-width = 140
            window-height = 45
            """)
        let app = try ghosttyApplication(defaultsSuite: "GHOSTTY_FILES_PANEL_UI_TESTS")
        app.launchArguments.append(contentsOf: [
            "-chostty.sidebarVisible", "NO",
            "-chostty.filesPanelVisible", "YES",
            "-chostty.filesPanelWidth", "320",
        ])
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.activate()
        let hideButton = window.buttons["Hide Files Panel"]
        if !hideButton.waitForExistence(timeout: 3) {
            let showMenuItem = app.menuBars.menuItems["Show Files Panel"]
            XCTAssertTrue(showMenuItem.waitForExistence(timeout: 5))
            showMenuItem.click()
        }
        XCTAssertTrue(app.textFields["files-panel-filter"].waitForExistence(timeout: 10))

        let fork = app.buttons["files-panel-row-\(repositoryRoot.appendingPathComponent("FORK.md").path)"]
        XCTAssertTrue(fork.waitForExistence(timeout: 15), "FORK.md is missing from the resolved root")
        fork.click()

        let reader = app.descendants(matching: .any)["files-panel-reader-overlay"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        XCTAssertTrue(reader.staticTexts["Chord"].waitForExistence(timeout: 10))
        XCTAssertTrue(reader.staticTexts["Action"].exists)

        app.activate()
        let readerScreenshot = XCTAttachment(screenshot: window.screenshot())
        readerScreenshot.name = "files-panel-reader"
        readerScreenshot.lifetime = .keepAlways
        add(readerScreenshot)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reader.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.exists)
    }
}
