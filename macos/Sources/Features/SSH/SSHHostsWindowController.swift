import AppKit
import Combine
import SwiftUI

@MainActor
final class SSHHostsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SSHHostsWindowController()

    private var model: SSHHostsEditorModel?
    private var services: SSHServices?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "SSH Hosts"
        window.center()
        window.setFrameAutosaveName("SSHHostsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(services: SSHServices) {
        if self.services !== services || model == nil {
            self.services?.catalog.stopWatching()
            let model = SSHHostsEditorModel(
                paths: services.paths,
                catalog: services.catalog,
                resolver: services.resolver,
                jumpHostChecker: SSHJumpHostChecker(loginEnvironment: services.loginEnvironment),
                secretStore: services.secretStore,
                tunnels: services.tunnels,
                passwordWarnings: services.$passwordWarnings.eraseToAnyPublisher(),
                clearPasswordWarning: { hostID in
                    services.setPasswordWarning(nil, for: hostID)
                },
                connect: { reference in
                    guard let capability = TerminalController.preferredParent?.sshCapability else {
                        return false
                    }
                    capability.connect(reference, inSplit: false)
                    return true
                })
            self.services = services
            self.model = model
            // Keep scrolling content below the traffic lights and preserve the
            // autosaved frame after assigning the hosting controller.
            let hosting = NSHostingController(rootView: SSHHostsView(model: model))
            hosting.sizingOptions = [.minSize]
            if let window {
                let frame = window.frame
                window.contentViewController = hosting
                window.setFrame(frame, display: false)
            }
        } else {
            model?.reloadIfClean()
        }

        services.catalog.startWatching()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        services?.catalog.stopWatching()
    }
}
