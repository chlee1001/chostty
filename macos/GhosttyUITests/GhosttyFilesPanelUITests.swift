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

        let readmeURL = repositoryRoot.appendingPathComponent("README.md")
        let readme = app.buttons["files-panel-row-\(readmeURL.path)"]
        XCTAssertTrue(readme.waitForExistence(timeout: 10))
        readme.click()
        XCTAssertTrue(app.descendants(matching: .any)["reader-document-tab-\(readmeURL.path)"].waitForExistence(timeout: 5))

        // Opening an existing path reselects its permanent tab rather than
        // adding another document.
        fork.click()
        XCTAssertTrue(app.descendants(matching: .any)[
            "reader-document-tab-\(repositoryRoot.appendingPathComponent("FORK.md").path)"
        ].waitForExistence(timeout: 5))

        app.activate()
        let readerScreenshot = XCTAttachment(screenshot: window.screenshot())
        readerScreenshot.name = "files-panel-reader"
        readerScreenshot.lifetime = .keepAlways
        add(readerScreenshot)

        app.activate()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reader.waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.exists)

        fork.click()
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        // Closing the selected document is asserted through the tab's own close
        // affordance. The Cmd+W chord routes to the same store call, but macOS
        // does not reliably deliver synthesized Command chords to the app under
        // test, which would make this assertion measure the automation layer
        // instead of the product.
        let forkTab = app.descendants(matching: .any)[
            "reader-document-tab-\(repositoryRoot.appendingPathComponent("FORK.md").path)"
        ]
        app.activate()
        forkTab.buttons["Close FORK.md"].click()
        XCTAssertTrue(forkTab.waitForNonExistence(timeout: 5), "closing the selected document should remove its tab")
        XCTAssertTrue(reader.exists, "the remaining document should stay open")
        XCTAssertTrue(app.descendants(matching: .any)["reader-document-tab-\(readmeURL.path)"].exists)
    }
}
