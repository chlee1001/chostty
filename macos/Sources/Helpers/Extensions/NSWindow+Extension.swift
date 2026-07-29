import AppKit

extension NSWindow {
    /// Get the CGWindowID type for the window (used for low level CoreGraphics APIs).
    var cgWindowId: CGWindowID? {
        // "If the window doesn’t have a window device, the value of this
        // property is equal to or less than 0." - Docs. In practice I've
        // found this is true if a window is not visible.
        guard windowNumber > 0 else { return nil }
        return CGWindowID(windowNumber)
    }

    /// Adjusts the window frame if necessary to ensure the window remains visible on screen.
    /// This constrains both the size (to not exceed the screen) and the origin (to keep the window on screen).
    func constrainToScreen() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        var windowFrame = frame

        windowFrame.size.width = min(windowFrame.size.width, visibleFrame.size.width)
        windowFrame.size.height = min(windowFrame.size.height, visibleFrame.size.height)

        windowFrame.origin.x = max(visibleFrame.minX,
            min(windowFrame.origin.x, visibleFrame.maxX - windowFrame.width))
        windowFrame.origin.y = max(visibleFrame.minY,
            min(windowFrame.origin.y, visibleFrame.maxY - windowFrame.height))

        if windowFrame != frame {
            setFrame(windowFrame, display: true)
        }
    }
}

/// Private-API access to the titlebar view, used only for titlebar text styling.
extension NSWindow {
    var titlebarView: NSView? {
        // In normal window, `NSTabBar` typically appears as a subview of `NSTitlebarView` within `NSThemeFrame`.
        // In fullscreen, the system creates a dedicated fullscreen window and the view hierarchy changes;
        // in that case, the `titlebarView` is only accessible via a reference on `NSThemeFrame`.
        // ref: https://github.com/mozilla-firefox/firefox/blob/054e2b072785984455b3b59acad9444ba1eeffb4/widget/cocoa/nsCocoaWindow.mm#L7205
        guard let themeFrameView = contentView?.rootView else { return nil }
        guard themeFrameView.responds(to: Selector(("titlebarView"))) else { return nil }
        return themeFrameView.value(forKey: "titlebarView") as? NSView
    }
}
