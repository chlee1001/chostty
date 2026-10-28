import AppKit
import SwiftUI

struct SSHToolbarButton: View {
    let capability: SSHCapability

    @StateObject private var presenter = SSHQuickConnectPresenter()

    var body: some View {
        Button {
            capability.services.catalog.refreshIfStale()
            presenter.toggle(capability: capability)
        } label: {
            Image(systemName: "terminal")
                .frame(width: 24, height: 24)
                // Preserve the titlebar accessory's fixed width.
                .overlay(alignment: .topTrailing) {
                    SSHTunnelBadge(tunnels: capability.services.tunnels)
                }
        }
        .buttonStyle(.plain)
        .help("SSH Hosts")
        .accessibilityLabel("SSH Hosts")
        // Expose the badge count that the button label hides.
        .modifier(SSHTunnelAccessibilityValue(tunnels: capability.services.tunnels))
        .background(SSHQuickConnectAnchor(presenter: presenter))
    }
}

/// SwiftUI closes a popover during view updates, which can publish terminal
/// focus changes in the same pass. AppKit closes it outside that update.
@MainActor
private final class SSHQuickConnectPresenter: NSObject, ObservableObject, NSPopoverDelegate {
    weak var anchor: NSView?
    /// Held from show until its own `didClose`, including the close animation.
    private var popover: NSPopover?
    private weak var controller: TerminalController?
    private weak var responderBeforeShow: NSResponder?
    /// A transient popover closes on the mouse-down of a click on its own
    /// button; that click's mouse-up must not open it again.
    private var closingClickTimestamp: TimeInterval?
    /// Clears the stamp once that click ends, wherever the mouse-up lands.
    private var closingClickMonitor: Any?

    func toggle(capability: SSHCapability) {
        let closingClick = closingClickTimestamp
        closingClickTimestamp = nil
        if let popover {
            popover.performClose(nil)
            return
        }
        if let closingClick, let event = NSApp.currentEvent, event.type == .leftMouseUp,
           event.timestamp >= closingClick {
            return
        }
        guard let anchor, let window = anchor.window else { return }

        let hosting = NSHostingController(rootView: SSHQuickConnectPopover(
            capability: capability,
            dismiss: { [weak self] in self?.close() }))
        hosting.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.delegate = self
        self.popover = popover
        controller = capability.controller
        responderBeforeShow = window.firstResponder
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
    }

    /// The anchor is leaving the view tree; nothing may outlive it.
    func tearDown() {
        close()
        endClosingClick()
    }

    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover,
              let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let anchor, event.window === anchor.window,
              anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        else { return }
        closingClickTimestamp = event.timestamp
        guard closingClickMonitor == nil else { return }
        closingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // The button action for this mouse-up runs before this block.
            DispatchQueue.main.async { self?.endClosingClick() }
            return event
        }
    }

    private func endClosingClick() {
        closingClickTimestamp = nil
        if let closingClickMonitor {
            NSEvent.removeMonitor(closingClickMonitor)
        }
        closingClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        let previous = responderBeforeShow
        responderBeforeShow = nil
        guard let surface = controller?.focusedSurface, let window = surface.window else { return }
        // Return to the terminal only when the close left focus where it was;
        // a click that closed the popover keeps the focus it gave.
        DispatchQueue.main.async { [weak previous] in
            let current = window.firstResponder
            guard current == nil || current === window || current === previous else { return }
            window.makeFirstResponder(surface)
        }
    }
}

private struct SSHQuickConnectAnchor: NSViewRepresentable {
    let presenter: SSHQuickConnectPresenter

    func makeCoordinator() -> SSHQuickConnectPresenter { presenter }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: SSHQuickConnectPresenter) {
        coordinator.tearDown()
    }
}

private struct SSHTunnelBadge: View {
    @ObservedObject var tunnels: SSHTunnelController

    var body: some View {
        let count = tunnels.manager.activeCount
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 5, y: -4)
        }
    }

    static func accessibilityValue(for count: Int) -> String {
        count == 0 ? "" : "\(count) running \(count == 1 ? "tunnel" : "tunnels")"
    }
}

private struct SSHTunnelAccessibilityValue: ViewModifier {
    @ObservedObject var tunnels: SSHTunnelController

    func body(content: Content) -> some View {
        content.accessibilityValue(SSHTunnelBadge.accessibilityValue(for: tunnels.manager.activeCount))
    }
}
