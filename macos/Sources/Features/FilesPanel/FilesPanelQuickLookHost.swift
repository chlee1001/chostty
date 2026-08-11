import AppKit
import SwiftUI

struct FilesPanelQuickLookResponderView: NSViewRepresentable {
    let action: () -> Bool

    func makeNSView(context: Context) -> ResponderView {
        ResponderView(action: action)
    }

    func updateNSView(_ nsView: ResponderView, context: Context) {
        nsView.action = action
    }

    final class ResponderView: NSView {
        var action: () -> Bool

        init(action: @escaping () -> Bool) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { false }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.keyCode == 49 else { return super.performKeyEquivalent(with: event) }
            return action() || super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode != 49 || !action() {
                super.keyDown(with: event)
            }
        }
    }
}
