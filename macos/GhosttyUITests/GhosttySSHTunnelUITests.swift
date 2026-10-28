import AppKit
import Darwin
import Foundation
import XCTest

/// Live tunnel coverage uses only the disposable SSH fixture supplied by the test runner.
final class GhosttySSHTunnelUITests: GhosttyCustomConfigCase {
    private struct TunnelFixture {
        let name: String
        let kind: String
        let port: Int
        let expectedStatus: String
    }

    private var root: URL!
    private var application: XCUIApplication?
    private var launchedProcessID: pid_t?
    private var tunnelPorts: Set<Int> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "Host ui-readonly\n    HostName 127.0.0.1\n    User nobody\n    Port 1\n"
            .write(to: root.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("managed"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The sandboxed test runner cannot list or signal other processes; the
        // test runner reaps any ssh left on the reserved ports.
        await MainActor.run { application?.terminate() }
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // L and D become ready, R stays running but unconfirmed.
    @MainActor
    func testLiveTunnelKindsShowStatusesBadgeAndLocalForward() throws {
        let tunnels = try configureLiveHost(tunnels: [
            TunnelFixture(name: "local", kind: "local", port: try freePort(), expectedStatus: "ready"),
            TunnelFixture(name: "dynamic", kind: "dynamic", port: try freePort(), expectedStatus: "ready"),
            TunnelFixture(name: "remote", kind: "remote", port: try freePort(), expectedStatus: "running, unconfirmed"),
        ])
        let app = try launch()
        XCTAssertTrue(wait(until: { self.sidebarTabCount(app) == 1 }, timeout: 10), app.debugDescription)
        let initialPaneCount = app.textViews.count
        let manager = openHostsManager(app)

        for tunnel in tunnels {
            start(tunnel, in: manager)
            XCTAssertTrue(
                element(labeled: "\(tunnel.name), \(tunnel.expectedStatus)", in: manager)
                    .waitForExistence(timeout: 20),
                manager.debugDescription)
        }

        XCTAssertTrue(waitForBadge("3 running tunnels", in: app), app.windows.firstMatch.debugDescription)
        // Tunnels never add tabs or panes.
        XCTAssertEqual(sidebarTabCount(app), 1, app.debugDescription)
        XCTAssertEqual(app.textViews.count, initialPaneCount)
        XCTAssertTrue(waitForSSHBanner(on: tunnels[0].port, timeout: 8),
                      "The local tunnel did not return an SSH identification banner.")
    }

    // Terminal lifetime is independent from the tunnel manager's process lifetime.
    @MainActor
    func testClosingTerminalTabDoesNotStopRunningTunnel() throws {
        let tunnel = try configureLiveHost(tunnels: [
            TunnelFixture(name: "local", kind: "local", port: try freePort(), expectedStatus: "ready"),
        ])[0]
        let app = try launch()
        let manager = openHostsManager(app)
        start(tunnel, in: manager)
        XCTAssertTrue(element(labeled: "local, ready", in: manager).waitForExistence(timeout: 20),
                      manager.debugDescription)
        XCTAssertTrue(waitForBadge("1 running tunnel", in: app), app.windows.firstMatch.debugDescription)

        // Close the manager so the tab shortcuts reach the terminal window.
        manager.buttons["_XCUI:CloseWindow"].click()
        XCTAssertTrue(manager.waitForNonExistence(timeout: 5), app.debugDescription)
        let terminal = app.textViews.firstMatch
        terminal.click()
        XCTAssertTrue(wait(until: { self.sidebarTabCount(app) == 1 }, timeout: 5), app.debugDescription)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(wait(until: { self.sidebarTabCount(app) == 2 }, timeout: 5), app.debugDescription)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(wait(until: { self.sidebarTabCount(app) == 1 }, timeout: 5), app.debugDescription)

        XCTAssertTrue(waitForBadge("1 running tunnel", in: app), app.windows.firstMatch.debugDescription)
        XCTAssertTrue(waitForSSHBanner(on: tunnel.port, timeout: 8))
        let reopenedManager = openHostsManager(app)
        XCTAssertTrue(element(labeled: "local, ready", in: reopenedManager).waitForExistence(timeout: 5),
                      reopenedManager.debugDescription)
    }

    // Normal quit has no confirmation and leaves no ssh for this test's tunnel port.
    @MainActor
    func testCommandQStopsTunnelWithoutConfirmation() throws {
        let tunnel = try configureLiveHost(tunnels: [
            TunnelFixture(name: "local", kind: "local", port: try freePort(), expectedStatus: "ready"),
        ])[0]
        let app = try launch()
        let manager = openHostsManager(app)
        start(tunnel, in: manager)
        XCTAssertTrue(element(labeled: "local, ready", in: manager).waitForExistence(timeout: 20),
                      manager.debugDescription)
        XCTAssertTrue(waitForSSHBanner(on: tunnel.port, timeout: 8))

        let processID = try XCTUnwrap(launchedProcessID)
        // Quit while the manager is the key window, as a user would after starting a tunnel.
        manager.staticTexts["Status"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        // Synthesized keys go to the frontmost app; make sure that is Chostty.
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), app.debugDescription)
        XCTAssertTrue(wait(until: { !self.isProcessRunning(processID) }, timeout: 10),
                      "The launched Chostty instance did not quit.")
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(waitForPortClosed(tunnel.port, timeout: 8),
                      "The tunnel ssh for port \(tunnel.port) still listens after Command-Q.")
        application = nil
    }

    // The watchdog lifeline must reap the app-owned ssh after SIGKILL.
    @MainActor
    func testKillNineAppReapsTunnelSSH() throws {
        let tunnel = try configureLiveHost(tunnels: [
            TunnelFixture(name: "local", kind: "local", port: try freePort(), expectedStatus: "ready"),
        ])[0]
        let app = try launch()
        let manager = openHostsManager(app)
        start(tunnel, in: manager)
        XCTAssertTrue(element(labeled: "local, ready", in: manager).waitForExistence(timeout: 20),
                      manager.debugDescription)
        XCTAssertTrue(waitForSSHBanner(on: tunnel.port, timeout: 8))

        let runningApplication = try XCTUnwrap(launchedRunningApplication())
        XCTAssertEqual(kill(runningApplication.processIdentifier, SIGKILL), 0)
        application = nil
        XCTAssertTrue(waitForPortClosed(tunnel.port, timeout: 8),
                      "The watchdog did not reap the ssh listening on port \(tunnel.port).")
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        try updateConfig("""
        command = /usr/bin/env -i HOME="\(root.path)" USER=ssh-ui LOGNAME=ssh-ui PATH=/usr/bin:/bin TERM=xterm-ghostty PS1="SSH_TUNNEL_UI_PROMPT> " /bin/sh -i
        working-directory = \(root.path)
        window-save-state = never
        window-position-x = 100
        window-position-y = 100
        macos-titlebar-style = transparent
        confirm-close-surface = false
        """)
        // Quit confirmation comes only from live terminal surfaces; tunnels never add
        // one. Turning off the local shell's prompt leaves any dialog to the tunnels.
        let app = try ghosttyApplication(defaultsSuite: "SSH_TUNNEL_UI_\(UUID().uuidString)")
        app.launchEnvironment["HOME"] = root.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = root.appendingPathComponent(".config").path
        app.launchEnvironment["CHOSTTY_SSH_DATA_DIR"] = root.appendingPathComponent("managed").path
        app.launchArguments += ["-chostty.sidebarVisible", "YES"]
        application = app
        // XCUIApplication exposes no pid on macOS; the launched instance is the
        // one debug-bundle process that did not exist before launch.
        let bundleIdentifier = "kr.co.devch.chostty.debug"
        let existing = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier))
        app.launch()
        let launched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !existing.contains($0.processIdentifier) }
        XCTAssertEqual(launched.count, 1, "Expected exactly one newly launched Chostty debug process")
        launchedProcessID = launched.first?.processIdentifier
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let shellReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "SSH_TUNNEL_UI_PROMPT>"),
            object: app.textViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [shellReady], timeout: 10), .completed,
                       app.windows.firstMatch.debugDescription)
        return app
    }

    @MainActor
    private func openHostsManager(_ app: XCUIApplication) -> XCUIElement {
        let button = app.windows.firstMatch.buttons["SSH Hosts"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        let search = app.textFields["Connect to host…"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        let manage = app.buttons["Manage SSH Hosts…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        manage.click()
        let manager = app.windows["SSH Hosts"]
        XCTAssertTrue(manager.waitForExistence(timeout: 5), app.windows.firstMatch.debugDescription)
        return manager
    }

    @MainActor
    private func start(_ tunnel: TunnelFixture, in manager: XCUIElement) {
        let row = element(labeled: "\(tunnel.name), stopped", in: manager)
        XCTAssertTrue(row.waitForExistence(timeout: 5), manager.debugDescription)
        row.click()
        let start = manager.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), manager.debugDescription)
        start.click()
    }

    private func configureLiveHost(
        tunnels fixtures: [TunnelFixture]
    ) throws -> [TunnelFixture] {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["CHOSTTY_SSH_UI_PORT"],
              let identity = environment["CHOSTTY_SSH_UI_IDENTITY"],
              let knownHosts = environment["CHOSTTY_SSH_UI_KNOWN_HOSTS"] else {
            throw XCTSkip("Requires the disposable loopback SSH fixture.")
        }
        let hostID = UUID()
        let hosts = root.appendingPathComponent("managed/hosts.conf")
        try """
        # chostty-host-id: \(hostID.uuidString)
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

        """.write(to: hosts, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hosts.path)

        let hostReference: [String: Any] = [
            "source": ["managed": ["hostID": hostID.uuidString]],
            "alias": "ui-live",
        ]
        let tunnelDefinitions: [[String: Any]] = fixtures.map { tunnel in
            var definition: [String: Any] = [
                "id": UUID().uuidString,
                "name": tunnel.name,
                "host": hostReference,
                "kind": tunnel.kind,
                "bindAddress": "127.0.0.1",
                "bindPort": tunnel.port,
            ]
            if tunnel.kind != "dynamic" {
                definition["targetHost"] = "127.0.0.1"
                definition["targetPort"] = 22
            }
            return definition
        }
        let hostMetadata: [String: Any] = [:]
        let metadata: [String: Any] = [
            "version": 1,
            "hosts": [hostID.uuidString: hostMetadata],
            "favorites": [Any](),
            "tunnels": tunnelDefinitions,
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        let metadataFile = root.appendingPathComponent("managed/hosts.meta.json")
        try metadataData.write(to: metadataFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataFile.path)
        return fixtures
    }

    /// Returns a loopback port the test runner reserved for this run. The sandboxed UI
    /// test runner may connect but not bind, so it cannot probe for free ports itself.
    private func freePort() throws -> Int {
        guard let ports = ProcessInfo.processInfo.environment["CHOSTTY_SSH_UI_TUNNEL_PORTS"] else {
            throw XCTSkip("Requires tunnel ports reserved by the test runner.")
        }
        let candidates = ports.split(separator: ",").compactMap { Int($0) }
        // Different tests in one run share the list; start from a per-test offset.
        let offset = abs(name.hashValue) % max(candidates.count, 1)
        for index in candidates.indices {
            let port = candidates[(index + offset) % candidates.count]
            if !sshBanner(on: port), tunnelPorts.insert(port).inserted {
                return port
            }
        }
        throw XCTSkip("No reserved tunnel port is free.")
    }

    private func waitForSSHBanner(on port: Int, timeout: TimeInterval) -> Bool {
        wait(until: { self.sshBanner(on: port) }, timeout: timeout)
    }

    private func sshBanner(on port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 256)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else { return false }
        return String(bytes: buffer.prefix(Int(received)), encoding: .utf8)?.hasPrefix("SSH-2.0-") == true
    }

    private func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    private func element(labeled label: String, in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", label, label))
            .firstMatch
    }

    private func launchedRunningApplication() -> NSRunningApplication? {
        guard let launchedProcessID else { return nil }
        for bundleIdentifier in ["kr.co.devch.chostty.debug", "kr.co.devch.chostty"] {
            if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { $0.processIdentifier == launchedProcessID }) {
                return application
            }
        }
        return nil
    }

    /// The workspace row's tab count, shown as a bare number in the sidebar.
    @MainActor
    private func sidebarTabCount(_ app: XCUIApplication) -> Int? {
        let window = app.windows.matching(NSPredicate(format: "title != %@", "SSH Hosts")).firstMatch
        let counts = window.staticTexts.allElementsBoundByIndex.compactMap { element -> Int? in
            guard element.frame.maxX < window.frame.midX else { return nil }
            return (element.value as? String).flatMap { Int($0) }
        }
        return counts.count == 1 ? counts[0] : nil
    }

    @MainActor
    private func waitForBadge(_ value: String, in app: XCUIApplication) -> Bool {
        // The manager window may be in front; the button lives in the terminal window.
        let button = app.buttons.matching(NSPredicate(format: "label == %@", "SSH Hosts")).firstMatch
        return wait(until: { button.exists && (button.value as? String) == value }, timeout: 5)
    }

    /// True once nothing accepts connections on the forward's local port, which
    /// means the ssh that owned the listener has exited.
    private func waitForPortClosed(_ port: Int, timeout: TimeInterval) -> Bool {
        wait(until: { !self.acceptsConnections(on: port) }, timeout: timeout)
    }

    private func acceptsConnections(on port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { _ = close(descriptor) }
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0 || errno != ECONNREFUSED
    }

    private func isProcessRunning(_ processID: pid_t) -> Bool {
        guard kill(processID, 0) == 0 else { return errno != ESRCH }
        return true
    }

    private func wait(until condition: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }
}
