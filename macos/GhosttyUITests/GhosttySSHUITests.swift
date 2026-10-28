import AppKit
import XCTest

/// Run from Xcode with accessibility permission, like the other GUI suites.
final class GhosttySSHUITests: GhosttyCustomConfigCase {
    private var root: URL!
    private var application: XCUIApplication?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "Host ui-readonly\n    HostName 127.0.0.1\n    User nobody\n    Port 1\n"
            .write(to: root.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        // OpenSSH resolves its default home through passwd, not HOME. Managed hosts
        // force -F to this fixture rather than reading the developer's SSH config.
        try """
        # chostty-host-id: \(UUID().uuidString)
        Host ui-main
            HostName 127.0.0.1
            User nobody
            Port 1
            UserKnownHostsFile /dev/null
            GlobalKnownHostsFile /dev/null
            IdentityFile /dev/null
            IdentityAgent none
        """.write(to: managed.appendingPathComponent("hosts.conf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: managed.appendingPathComponent("hosts.conf").path)
    }

    override func tearDown() async throws {
        await MainActor.run { application?.terminate() }
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    @MainActor
    private func launch(
        config: String = "macos-titlebar-style = transparent",
        sidebar: Bool = true,
        filesPanel: Bool = false
    ) throws -> XCUIApplication {
        try updateConfig("""
        command = /usr/bin/env -i HOME="\(root.path)" USER=ssh-ui LOGNAME=ssh-ui PATH=/usr/bin:/bin TERM=xterm-ghostty PS1="SSH_UI_PROMPT> " /bin/sh -i
        working-directory = \(root.path)
        window-save-state = never
        window-position-x = 100
        window-position-y = 100
        """ + "\n" + config)
        let app = try ghosttyApplication(defaultsSuite: "SSH_UI_\(UUID().uuidString)")
        app.launchEnvironment["HOME"] = root.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = root.appendingPathComponent(".config").path
        app.launchEnvironment["CHOSTTY_SSH_DATA_DIR"] = root.appendingPathComponent("managed").path
        // Both panels persist in the standard domain the Debug app shares with other
        // Debug copies, so pin them instead of inheriting whatever was last saved.
        app.launchArguments += [
            "-chostty.sidebarVisible", sidebar ? "YES" : "NO",
            "-chostty.filesPanelVisible", filesPanel ? "YES" : "NO",
        ]
        application = app
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let shellReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "SSH_UI_PROMPT>"),
            object: app.textViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [shellReady], timeout: 10), .completed,
                       app.windows.firstMatch.debugDescription)
        return app
    }

    private struct LiveFixture {
        let port: String
        let identity: String
        let knownHosts: String
    }

    private func liveFixture() throws -> LiveFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["CHOSTTY_SSH_UI_PORT"],
              let identity = environment["CHOSTTY_SSH_UI_IDENTITY"],
              let knownHosts = environment["CHOSTTY_SSH_UI_KNOWN_HOSTS"] else {
            throw XCTSkip("Requires the disposable loopback SSH fixture.")
        }
        return LiveFixture(port: port, identity: identity, knownHosts: knownHosts)
    }

    private func writeLiveHost(_ fixture: LiveFixture, remoteCommand: String) throws {
        let config = """
        # chostty-host-id: \(UUID().uuidString)
        Host ui-live
            HostName 127.0.0.1
            User qa
            Port \(fixture.port)
            IdentityFile "\(fixture.identity)"
            IdentityAgent none
            IdentitiesOnly yes
            StrictHostKeyChecking yes
            UserKnownHostsFile "\(fixture.knownHosts)"
            GlobalKnownHostsFile /dev/null
            RequestTTY force
            RemoteCommand \(remoteCommand)

        """
        let hostsFile = root.appendingPathComponent("managed/hosts.conf")
        try config.write(to: hostsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostsFile.path)
    }

    @MainActor
    private func sidebarTabCount(_ app: XCUIApplication) -> Int {
        // The workspace row shows its tab count as a bare number in the sidebar.
        let sidebarTexts = app.staticTexts.allElementsBoundByIndex.compactMap { element -> Int? in
            guard element.frame.maxX < app.windows.firstMatch.frame.midX else { return nil }
            return Int(element.label) ?? (element.value as? String).flatMap { Int($0) }
        }
        XCTAssertEqual(sidebarTexts.count, 1, app.windows.firstMatch.debugDescription)
        return sidebarTexts.first ?? -1
    }

    @MainActor
    private func connectLiveHost(_ app: XCUIApplication) -> XCUIElement {
        _ = openSearch(app)
        let host = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", "ui-live", "ui-live, ")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.click()
        return app.textViews.firstMatch
    }

    @MainActor
    private func waitForTerminalText(_ text: String, in terminal: XCUIElement, app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       app.windows.firstMatch.debugDescription)
    }

    @MainActor
    private func openSearch(_ app: XCUIApplication) -> XCUIElement {
        let button = app.windows.firstMatch.buttons["SSH Hosts"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        // A transient popover closes when another app takes focus; start from the front.
        app.activate()
        button.click()
        let search = app.textFields["Connect to host…"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        return search
    }

    @MainActor
    private func openHostsManager(_ app: XCUIApplication) -> XCUIElement {
        let search = openSearch(app)
        let manage = app.buttons["Manage SSH Hosts…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        manage.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), app.windows.firstMatch.debugDescription)

        let manager = app.windows["SSH Hosts"]
        XCTAssertTrue(manager.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        return manager
    }

    @MainActor
    private func uiMainRow(_ app: XCUIApplication, search: XCUIElement) -> XCUIElement {
        XCTAssertEqual(search.value as? String, "ui-main", app.debugDescription)
        let row = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", "ui-main", "ui-main, "
        )).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "\(app.windows.firstMatch.debugDescription)\nSearch value: \(String(describing: search.value))"
        )
        return row
    }

    @MainActor
    private func closeFocusedPane(_ app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        let confirmation = app.sheets.buttons["Close"]
        if confirmation.waitForExistence(timeout: 2) {
            confirmation.click()
        }
    }

    @MainActor
    func testTitlebarButtonWorksWithSidebarClosedAndSearchNeverRunsMatchExec() throws {
        let sentinel = root.appendingPathComponent("match-exec-ran")
        let config = root.appendingPathComponent(".ssh/config")
        let original = try String(contentsOf: config, encoding: .utf8) + "Match exec \"touch \(sentinel.path)\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let app = try launch(sidebar: false)
        let search = openSearch(app)
        search.typeText("unregistered@10.0.0.5")
        XCTAssertTrue(app.staticTexts["No matching hosts"].waitForExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        let reopened = openSearch(app)
        reopened.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 5))
    }

    /// Titlebar controls remain sidebar toggle → files → SSH → actions, without a tunnel badge.
    @MainActor
    func testTitlebarSSHButtonOrderAndNoRunningTunnelBadge() throws {
        let app = try launch()
        let window = app.windows.firstMatch
        let sidebar = window.buttons["Hide Sidebar"]
        let files = window.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@", "Hide Files Panel", "Show Files Panel")).firstMatch
        let ssh = window.buttons["SSH Hosts"]
        let actions = window.menuButtons.matching(NSPredicate(
            format: "title == %@ OR label == %@", "Workspace Actions", "Workspace Actions")).firstMatch
        for button in [sidebar, files, ssh, actions] {
            XCTAssertTrue(button.waitForExistence(timeout: 10), window.debugDescription)
        }
        XCTAssertLessThan(sidebar.frame.minX, files.frame.minX)
        XCTAssertLessThan(files.frame.minX, ssh.frame.minX)
        XCTAssertLessThan(ssh.frame.minX, actions.frame.minX)
        XCTAssertEqual(ssh.value as? String ?? "", "", window.debugDescription)
    }

    @MainActor
    func testFullscreenStripHasSSHButtonWithSidebarClosed() throws {
        let app = try launch(config: "fullscreen = true\nmacos-non-native-fullscreen = true", sidebar: false)
        _ = openSearch(app)
    }

    @MainActor
    func testHiddenTitlebarHeaderHasSSHButton() throws {
        let app = try launch(config: "macos-titlebar-style = hidden")
        _ = openSearch(app)
    }

    @MainActor
    func testSearchLiteralTextFiltersHosts() throws {
        let app = try launch()
        let search = openSearch(app)
        search.typeText("ui-main")
        _ = uiMainRow(app, search: search)
    }

    @MainActor
    func testReturnCreatesSSHConnectionTabAndRetainsFailedConnection() throws {
        try "".write(to: root.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let app = try launch()
        let search = openSearch(app)
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        XCTAssertTrue(app.staticTexts["Couldn't connect to ui-main."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Reconnect ↩"].isHittable)
        let connectionLost = app.staticTexts.matching(NSPredicate(
            format: "label ENDSWITH %@ OR value ENDSWITH %@", " · connection lost", " · connection lost"
        )).firstMatch
        XCTAssertTrue(connectionLost.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        let renderedStatus = connectionLost.label.isEmpty
            ? (connectionLost.value as? String ?? "")
            : connectionLost.label
        XCTAssertTrue(renderedStatus.contains("127.0.0.1"), app.windows.firstMatch.debugDescription)
    }

    /// Opens ui-main, whose port refuses, and waits for the disconnected pane.
    @MainActor
    private func openFailedConnection(_ app: XCUIApplication) {
        let search = openSearch(app)
        let row = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", "ui-main", "ui-main, ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Couldn't connect to ui-main."].waitForExistence(timeout: 15),
                      app.debugDescription)
        let terminalFocus = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.textViews.firstMatch.debugDescription.components(separatedBy: "\n")
                    .contains { $0.contains("TextView") && $0.contains("Keyboard Focused") }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [terminalFocus], timeout: 5), .completed,
                       app.windows.firstMatch.debugDescription)
    }

    @MainActor
    func testDisconnectedPaneSelectionCopies() throws {
        let app = try launch()
        openFailedConnection(app)
        NSPasteboard.general.clearContents()
        let initialChangeCount = NSPasteboard.general.changeCount
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(5)
        var copied = ""
        while Date() < deadline {
            copied = NSPasteboard.general.string(forType: .string) ?? ""
            if copied.contains("ssh exited with status") { break }
            usleep(100_000)
        }
        XCTAssertTrue(copied.contains("ssh exited with status"),
                      "Clipboard changes: \(NSPasteboard.general.changeCount - initialChangeCount)\n"
                      + app.windows.firstMatch.debugDescription)
    }

    @MainActor
    func testDisconnectedPaneKeepsTabSplitAndCloseShortcuts() throws {
        let app = try launch()
        openFailedConnection(app)
        let overlay = app.staticTexts["Couldn't connect to ui-main."]

        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.groups["Right pane"].waitForExistence(timeout: 10))
        closeFocusedPane(app)
        XCTAssertTrue(app.groups["Right pane"].waitForNonExistence(timeout: 10),
                      app.windows.firstMatch.debugDescription)
        XCTAssertTrue(overlay.exists)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 10))
        closeFocusedPane(app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.exists, app.windows.firstMatch.debugDescription)
    }

    /// A disconnected SSH pane still permits the command palette shortcut.
    @MainActor
    func testDisconnectedPaneOpensCommandPalette() throws {
        let app = try launch()
        openFailedConnection(app)
        app.typeKey("p", modifierFlags: [.command, .shift])
        let palette = app.textFields["Execute a command…"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
    }

    /// Quitting with a disconnected SSH pane terminates without confirmation.
    @MainActor
    func testDisconnectedPaneQuitsWithoutConfirmation() throws {
        let app = try launch()
        openFailedConnection(app)
        // The launch tab runs a live local shell, which rightly asks before quitting.
        // Close it so only the disconnected SSH pane is left to judge.
        let localTab = app.windows.firstMatch.staticTexts.matching(NSPredicate(
            format: "value == %@", "👻")).allElementsBoundByIndex
            .filter { $0.frame.maxX < app.windows.firstMatch.frame.midX }
            .first
        try XCTUnwrap(localTab, app.windows.firstMatch.debugDescription).click()
        closeFocusedPane(app)
        XCTAssertEqual(sidebarTabCount(app), 1, app.windows.firstMatch.debugDescription)
        XCTAssertTrue(app.buttons["Reconnect ↩"].waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        // Synthesized keys go to the frontmost app; make sure that is Chostty.
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), app.debugDescription)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    /// Option-Return connects in a right split without adding a sidebar tab.
    @MainActor
    func testOptionReturnSplitsRight() throws {
        try "".write(to: root.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let app = try launch()
        let tabCount = sidebarTabCount(app)
        let search = openSearch(app)
        search.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        XCTAssertTrue(app.groups["Right pane"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.groups.matching(identifier: "Right pane").count, 1)
        XCTAssertEqual(sidebarTabCount(app), tabCount, app.windows.firstMatch.debugDescription)
    }

    @MainActor
    func testManageSSHHostsKeepsTerminalAndFixtureConfig() throws {
        let config = root.appendingPathComponent(".ssh/config")
        let originalConfig = try String(contentsOf: config, encoding: .utf8)
        let app = try launch()
        let terminal = app.windows.containing(.button, identifier: "SSH Hosts").firstMatch
        XCTAssertTrue(terminal.exists, app.windows.firstMatch.debugDescription)

        let manager = openHostsManager(app)
        XCTAssertEqual(app.windows.count, 2, app.windows.firstMatch.debugDescription)
        XCTAssertTrue(terminal.exists, app.windows.firstMatch.debugDescription)
        XCTAssertTrue(manager.staticTexts["CHOSTTY HOSTS"].waitForExistence(timeout: 5),
                      manager.debugDescription)
        XCTAssertTrue(manager.staticTexts["FROM ~/.ssh/config"].waitForExistence(timeout: 5),
                      manager.debugDescription)
        let tunnels = manager.staticTexts["ssh.tunnels-heading"]
        XCTAssertTrue(tunnels.waitForExistence(timeout: 5),
                      manager.debugDescription)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), originalConfig)
    }

    @MainActor
    func testManagedHostSaveUsesSecureStoreWithoutMutatingSSHConfig() throws {
        let config = root.appendingPathComponent(".ssh/config")
        let originalConfig = try String(contentsOf: config, encoding: .utf8)
        let hostsFile = root.appendingPathComponent("managed/hosts.conf")
        let app = try launch()
        let manager = openHostsManager(app)

        let addHost = manager.buttons["Add SSH host"]
        XCTAssertTrue(addHost.waitForExistence(timeout: 5), manager.debugDescription)
        addHost.click()

        let savedTo = manager.staticTexts["ssh.saved-to"]
        XCTAssertTrue(savedTo.waitForExistence(timeout: 5), manager.debugDescription)
        XCTAssertEqual(savedTo.label, "Saved to ~/managed/hosts.conf")
        let alias = manager.textFields["Alias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 5), manager.debugDescription)
        alias.click()
        alias.typeText("managed-ui")
        let hostName = manager.textFields["HostName"]
        XCTAssertTrue(hostName.waitForExistence(timeout: 5), manager.debugDescription)
        hostName.click()
        hostName.typeText("127.0.0.1")

        let save = manager.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), manager.debugDescription)
        save.click()

        let fileSaved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let contents = try? String(contentsOf: hostsFile, encoding: .utf8) else {
                    return false
                }
                return contents.contains("Host managed-ui") && contents.contains("HostName 127.0.0.1")
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [fileSaved], timeout: 5), .completed, manager.debugDescription)
        let attributes = try FileManager.default.attributesOfItem(atPath: hostsFile.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, manager.debugDescription)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), originalConfig)
        XCTAssertTrue(manager.buttons["Delete…"].waitForExistence(timeout: 5), manager.debugDescription)
        XCTAssertFalse(manager.buttons["Delete SSH host"].exists, manager.debugDescription)
    }

    /// Choosing a saved host as the jump host and checking it signs in to the
    /// loopback fixture without prompting.
    @MainActor
    func testLiveJumpHostCheckSignsIn() throws {
        let fixture = try liveFixture()
        let hostsFile = root.appendingPathComponent("managed/hosts.conf")
        try """
        # chostty-host-id: \(UUID().uuidString)
        Host ui-jump
            HostName 127.0.0.1
            User qa
            Port \(fixture.port)
            IdentityFile "\(fixture.identity)"
            IdentityAgent none
            IdentitiesOnly yes
            StrictHostKeyChecking yes
            UserKnownHostsFile "\(fixture.knownHosts)"
            GlobalKnownHostsFile /dev/null

        """.write(to: hostsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostsFile.path)
        let app = try launch()
        let manager = openHostsManager(app)
        let addHost = manager.buttons["Add SSH host"]
        XCTAssertTrue(addHost.waitForExistence(timeout: 5), manager.debugDescription)
        addHost.click()

        let jumpHost = manager.popUpButtons["ssh.jump-host"]
        XCTAssertTrue(jumpHost.waitForExistence(timeout: 5), manager.debugDescription)
        jumpHost.click()
        let choice = app.menuItems["ui-jump"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.click()

        let check = manager.buttons["Check Jump Host"]
        XCTAssertTrue(check.waitForExistence(timeout: 5), manager.debugDescription)
        check.click()
        let result = manager.staticTexts["ssh.jump-check-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), manager.debugDescription)
        let text = (result.value as? String) ?? result.label
        XCTAssertEqual(text, "Signed in to qa@127.0.0.1:\(fixture.port).", manager.debugDescription)
    }

    /// Text fields outside the terminal cut, copy and paste with the standard
    /// chords. The user's pasteboard is saved first and restored afterwards.
    @MainActor
    func testHostEditorFieldsCutCopyAndPaste() throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        addTeardownBlock {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        }
        let app = try launch()
        let manager = openHostsManager(app)
        let addHost = manager.buttons["Add SSH host"]
        XCTAssertTrue(addHost.waitForExistence(timeout: 5), manager.debugDescription)
        addHost.click()

        let alias = manager.textFields["Alias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 5), manager.debugDescription)
        alias.click()
        alias.typeText("clip-alias")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("x", modifierFlags: .command)
        XCTAssertEqual(alias.value as? String ?? "", "", manager.debugDescription)

        let hostName = manager.textFields["HostName"]
        hostName.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(hostName.value as? String, "clip-alias", manager.debugDescription)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)

        let user = manager.textFields["User"]
        user.click()
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(user.value as? String, "clip-alias", manager.debugDescription)
        XCTAssertEqual(pasteboard.string(forType: .string), "clip-alias")
    }

    /// Scanner diagnostics are visible when the SSH Hosts manager opens.
    @MainActor
    func testSSHHostsManagerShowsConfigScannerDiagnostic() throws {
        try "Host bad%alias\n    HostName 127.0.0.1\n"
            .write(to: root.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let app = try launch()
        let manager = openHostsManager(app)
        let diagnostic = manager.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "bad%alias", "bad%alias")).firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), manager.debugDescription)
    }

    /// A missing config, an unreadable file, an Include loop and a glob Include each
    /// show their own diagnostic, and an external edit updates the open manager.
    @MainActor
    func testSSHHostsManagerShowsEachDiagnosticAndFollowsExternalChange() throws {
        let ssh = root.appendingPathComponent(".ssh")
        let config = ssh.appendingPathComponent("config")
        try FileManager.default.removeItem(at: config)
        let app = try launch()
        let manager = openHostsManager(app)
        let diagnostic = { (text: String) in
            manager.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        }
        let missingConfig = diagnostic(".ssh/config doesn't exist.")
        XCTAssertTrue(missingConfig.waitForExistence(timeout: 5), manager.debugDescription)

        let confD = ssh.appendingPathComponent("conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)
        try "Host bad%glob\n    HostName 127.0.0.1\n"
            .write(to: confD.appendingPathComponent("extra.conf"), atomically: true, encoding: .utf8)
        try "Include loop.conf\n".write(to: ssh.appendingPathComponent("loop.conf"), atomically: true, encoding: .utf8)
        let locked = ssh.appendingPathComponent("locked.conf")
        try "Host locked\n".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        try """
        Include loop.conf
        Include conf.d/*.conf
        Include locked.conf
        Host ui-external
            HostName 127.0.0.1

        """.write(to: config, atomically: true, encoding: .utf8)

        for text in ["loop.conf is included in a loop", "Host bad%glob in ", "Chostty can't read "] {
            XCTAssertTrue(diagnostic(text).waitForExistence(timeout: 10), "\(text)\n\(manager.debugDescription)")
        }
        XCTAssertTrue(diagnostic("locked.conf").exists, manager.debugDescription)
        XCTAssertTrue(missingConfig.waitForNonExistence(timeout: 5), manager.debugDescription)
        let externalHost = manager.staticTexts.matching(NSPredicate(
            format: "label == %@ OR value == %@", "ui-external", "ui-external")).firstMatch
        XCTAssertTrue(externalHost.waitForExistence(timeout: 5), manager.debugDescription)
    }

    @MainActor
    func testCommandPaletteShowsKnownSSHActionsOnly() throws {
        let app = try launch()
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.textFields["Execute a command…"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        search.typeText("ssh")

        let connect = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "SSH: Connect to ui-main"
        )).firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5),
                      app.windows.firstMatch.debugDescription)
        let split = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "SSH: Connect to ui-main in Split"
        )).firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5),
                      app.windows.firstMatch.debugDescription)
        let manage = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "SSH: Manage Hosts…"
        )).firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 5),
                      app.windows.firstMatch.debugDescription)

        search.typeKey("a", modifierFlags: .command)
        search.typeText("unregistered@10.0.0.5")
        let unregistered = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "SSH: Connect to unregistered@10.0.0.5"
        )).firstMatch
        XCTAssertFalse(unregistered.exists,
                       app.windows.firstMatch.debugDescription)
    }

    @MainActor
    func testQuickTerminalHasNoSSHEntryPoints() throws {
        let app = try launch()
        app.menuItems["Quick Terminal"].firstMatch.click()
        let quick = app.windows["com.mitchellh.ghostty.quickTerminal"]
        XCTAssertTrue(quick.waitForExistence(timeout: 10), app.windows.firstMatch.debugDescription)
        XCTAssertFalse(quick.buttons["SSH Hosts"].exists, quick.debugDescription)

        quick.textViews.firstMatch.click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.textFields["Execute a command…"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), quick.debugDescription)
        search.typeText("ssh")
        let queryUpdated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ssh"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [queryUpdated], timeout: 5), .completed)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SSH:")).count, 0,
                       quick.debugDescription)
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    /// Duplicate Tab starts a second live SSH connection without another Return.
    @MainActor
    func testLiveDuplicateTabConnectsImmediately() throws {
        let fixture = try liveFixture()
        try writeLiveHost(
            fixture,
            remoteCommand: "printf 'SSH_LIVE_READY:%%s\\n' \"$$\"; sleep 20")
        let app = try launch()
        let originalTerminal = connectLiveHost(app)
        waitForTerminalText("SSH_LIVE_READY:", in: originalTerminal, app: app)
        let originalOutput = originalTerminal.value as? String ?? ""

        app.typeKey("p", modifierFlags: [.command, .shift])
        let palette = app.textFields["Execute a command…"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        palette.typeText("Duplicate Tab")
        let duplicate = app.buttons["Duplicate Tab"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        duplicate.click()

        let newTerminal = app.textViews.firstMatch
        let secondConnection = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let output = newTerminal.value as? String ?? ""
                return output.contains("SSH_LIVE_READY:") && output != originalOutput
            },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [secondConnection], timeout: 15), .completed,
                       app.windows.firstMatch.debugDescription)
    }

    /// The default SSH environment forces the portable remote TERM value.
    @MainActor
    func testLiveSSHDefaultConfigForwardsXterm256Color() throws {
        let fixture = try liveFixture()
        try writeLiveHost(
            fixture,
            remoteCommand: "printf 'TERM=%%s\\nSSH_TERM_READY\\n' \"$TERM\"; sleep 12")
        let app = try launch()
        let terminal = connectLiveHost(app)
        waitForTerminalText("SSH_TERM_READY", in: terminal, app: app)
        XCTAssertTrue((terminal.value as? String ?? "").contains("TERM=xterm-256color"),
                      app.windows.firstMatch.debugDescription)
    }

    /// Explicitly disabling ssh-env retains the local pty TERM value.
    @MainActor
    func testLiveSSHNoSSHEnvRetainsLocalTerm() throws {
        let fixture = try liveFixture()
        try writeLiveHost(
            fixture,
            remoteCommand: "printf 'TERM=%%s\\nSSH_TERM_READY\\n' \"$TERM\"; sleep 12")
        let app = try launch(config: "shell-integration-features = no-ssh-env")
        let terminal = connectLiveHost(app)
        waitForTerminalText("SSH_TERM_READY", in: terminal, app: app)
        XCTAssertTrue((terminal.value as? String ?? "").contains("TERM=xterm-ghostty"),
                      app.windows.firstMatch.debugDescription)
    }

    /// `ssh-terminfo` may fall back when the fixture lacks xterm-ghostty terminfo.
    @MainActor
    func testLiveSSHWithTerminfoUsesSupportedTermValue() throws {
        let fixture = try liveFixture()
        try writeLiveHost(
            fixture,
            remoteCommand: "printf 'TERM=%%s\\nSSH_TERM_READY\\n' \"$TERM\"; sleep 12")
        let app = try launch(config: "shell-integration-features = ssh-terminfo")
        let terminal = connectLiveHost(app)
        waitForTerminalText("SSH_TERM_READY", in: terminal, app: app)
        let output = terminal.value as? String ?? ""
        XCTAssertTrue(
            output.contains("TERM=xterm-ghostty") || output.contains("TERM=xterm-256color"),
            app.windows.firstMatch.debugDescription)
    }

    @MainActor
    func testLiveKeyConnectionLossAndSamePaneReconnect() throws {
        try exerciseLiveConnection(exitStatus: 255)
    }

    @MainActor
    func testLiveAlternateScreenLossPreservesPrimaryOutput() throws {
        try exerciseLiveConnection(exitStatus: 255, leavesAlternateScreen: true)
    }

    @MainActor
    func testLiveNormalLogoutClosesSSHPaneWithoutConfirmation() throws {
        try exerciseLiveConnection(exitStatus: 0)
    }

    @MainActor
    private func exerciseLiveConnection(exitStatus: Int, leavesAlternateScreen: Bool = false) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["CHOSTTY_SSH_UI_PORT"],
              let identity = environment["CHOSTTY_SSH_UI_IDENTITY"],
              let knownHosts = environment["CHOSTTY_SSH_UI_KNOWN_HOSTS"] else {
            throw XCTSkip("Requires the disposable loopback SSH fixture.")
        }
        let alternateScreen = leavesAlternateScreen ? "printf '\\033[?1049hALT_SCREEN'; sleep 1; " : ""
        let config = """
        # chostty-host-id: \(UUID().uuidString)
        Host ui-live
            HostName 127.0.0.1
            User qa
            Port \(port)
            IdentityFile "\(identity)"
            IdentityAgent none
            IdentitiesOnly yes
            StrictHostKeyChecking yes
            UserKnownHostsFile "\(knownHosts)"
            GlobalKnownHostsFile /dev/null
            RequestTTY force
            RemoteCommand printf 'SSH_LIVE_READY\\n'; sleep 8; \(alternateScreen)exit \(exitStatus)

        """
        try config.write(to: root.appendingPathComponent("managed/hosts.conf"),
                         atomically: true, encoding: .utf8)
        let app = try launch()
        _ = openSearch(app)
        let host = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", "ui-live", "ui-live, ")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.click()
        let terminal = app.textViews.firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "SSH_LIVE_READY"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       app.windows.firstMatch.debugDescription)
        let connected = app.staticTexts.matching(NSPredicate(
            format: "label ENDSWITH %@ OR value ENDSWITH %@", " · connected", " · connected")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        if exitStatus == 0 {
            let localShellRestored = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "SSH_UI_PROMPT>"),
                object: app.textViews.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [localShellRestored], timeout: 20), .completed,
                           app.windows.firstMatch.debugDescription)
            XCTAssertFalse(app.buttons["Reconnect ↩"].exists)
            XCTAssertFalse(app.sheets.firstMatch.exists)
            return
        }
        XCTAssertTrue(app.staticTexts["ssh exited with status 255."].waitForExistence(timeout: 20),
                      app.windows.firstMatch.debugDescription)
        let firstOutput = terminal.value as? String ?? ""
        XCTAssertTrue(firstOutput.contains("SSH_LIVE_READY"))
        let paneCount = app.textViews.count
        app.buttons["Reconnect ↩"].click()
        let reconnected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let output = terminal.value as? String ?? ""
                return output.components(separatedBy: "SSH_LIVE_READY").count >= 3
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reconnected], timeout: 15), .completed,
                       "Before reconnect:\n\(firstOutput)\nAfter reconnect:\n\(terminal.value as? String ?? "")")
        XCTAssertEqual(app.textViews.count, paneCount)
        XCTAssertTrue(app.staticTexts["ssh exited with status 255."].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(
            (terminal.value as? String ?? "").components(separatedBy: "SSH_LIVE_READY").count, 3)
        app.buttons["Close Tab ⌘W"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    @MainActor
    func testNarrowPopoverEscapeRestoresTerminalFocus() throws {
        let app = try launch(config: "window-width = 50\nwindow-height = 20", sidebar: false)
        let beforeSearch = app.textViews.firstMatch.value as? String
        let search = openSearch(app)
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        XCTAssertEqual(app.textViews.firstMatch.value as? String, beforeSearch)
        app.typeText("echo ssh_focus_o''k\n")
        let output = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ssh_focus_ok"),
            object: app.textViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 5), .completed,
                       app.windows.firstMatch.debugDescription)
    }

    /// A second click on the SSH button closes the popover; a third opens it again.
    @MainActor
    func testSSHButtonClickTogglesPopover() throws {
        let app = try launch()
        let search = openSearch(app)
        app.windows.firstMatch.buttons["SSH Hosts"].click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), app.debugDescription)

        let reopened = openSearch(app)
        reopened.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    /// Closing the popover by clicking another field leaves typing in that field.
    @MainActor
    func testClickAwayFromPopoverKeepsTheClickedFieldFocused() throws {
        // The sidebar filter sits under the popover; the files panel filter does not.
        let app = try launch(sidebar: false, filesPanel: true)
        let search = openSearch(app)
        let filter = app.windows.firstMatch.textFields["files-panel-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        filter.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), app.debugDescription)
        // The terminal restore runs a turn after close; it must not take the field back.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("zz")
        XCTAssertEqual(filter.value as? String, "zz", app.windows.firstMatch.debugDescription)
    }
}
