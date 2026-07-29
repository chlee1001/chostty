import AppKit

/// A terminal window style that provides a transparent titlebar effect. With this effect, the titlebar
/// matches the background color of the window.
class TransparentTitlebarTerminalWindow: TerminalWindow {
    /// Stores the last surface configuration to reapply appearance when needed.
    /// This is necessary because various macOS operations (tab switching, tab bar
    /// visibility changes) can reset the titlebar appearance.
    private var lastSurfaceConfig: Ghostty.SurfaceView.DerivedConfig?
    // MARK: NSWindow

    override func becomeMain() {
        super.becomeMain()

        guard let lastSurfaceConfig else { return }
        syncAppearance(lastSurfaceConfig)
    }

    override func update() {
        super.update()

        // On macOS 13 to 15, we need to hide the NSVisualEffectView in order to allow our
        // titlebar to be truly transparent.
        if #unavailable(macOS 26) {
            if !effectViewIsHidden {
                hideEffectView()
            }
        }
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        // override appearance based on the terminal's background color
        if let preferredBackgroundColor {
            appearance = (preferredBackgroundColor.isLightColor ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua))
        }

        // Save our config in case we need to reapply
        lastSurfaceConfig = surfaceConfig


        if #available(macOS 26.0, *) {
            syncAppearanceTahoe(surfaceConfig)
        } else {
            syncAppearanceVentura(surfaceConfig)
        }
    }

    @available(macOS 26.0, *)
    private func syncAppearanceTahoe(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // When we have transparency, we need to set the titlebar background to match the
        // window background but with opacity. The window background is set using the
        // "preferred background color" property.
        //
        // Even if we aren't transparent, we still set this because this becomes the
        // color of the titlebar in native fullscreen view.
        if let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true

            // For glass background styles, use a transparent titlebar to let the glass effect show through.
            // `tabs` is aliased to `transparent` at the config read site (IR 3), so it never
            // reaches here as a distinct value.
            let isGlassStyle = derivedConfig.backgroundBlur.isGlassStyle
            let isTransparentTitlebar = derivedConfig.macosTitlebarStyle == .transparent

            titlebarView.layer?.backgroundColor = (isGlassStyle && isTransparentTitlebar)
                ? NSColor.clear.cgColor
                : preferredBackgroundColor?.cgColor
        }

        // In all cases, we have to hide the background view since this has multiple subviews
        // that force a background color.
        titlebarBackgroundView?.isHidden = true
    }

    @available(macOS 13.0, *)
    private func syncAppearanceVentura(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let titlebarContainer else { return }

        // Setup the titlebar background color to match ours
        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = preferredBackgroundColor?.cgColor

        // See the docs for the function that sets this to true on why
        effectViewIsHidden = false

        // Necessary to not draw the border around the title
        titlebarAppearsTransparent = true
    }

    // MARK: View Finders

    private var titlebarBackgroundView: NSView? {
        titlebarContainer?.firstDescendant(withClassName: "NSTitlebarBackgroundView")
    }


    // MARK: macOS 13 to 15

    // We only need to set this once, but need to do it after the window has
    // been created in order for `titlebarContainer`'s descendant view
    // hierarchy to exist to search.
    private var effectViewIsHidden = false

    private func hideEffectView() {
        guard !effectViewIsHidden else { return }

        // By hiding the visual effect view, we allow the window's (or titlebar's in this case)
        // background color to show through. If we were to set `titlebarAppearsTransparent` to true
        // the selected tab would look fine, but the unselected ones and new tab button backgrounds
        // would be an opaque color. When the titlebar isn't transparent, however, the system applies
        // a compositing effect to the unselected tab backgrounds, which makes them blend with the
        // titlebar's/window's background.
        if let effectView = titlebarContainer?.descendants(withClassName: "NSVisualEffectView").first {
            effectView.isHidden = true
        }

        effectViewIsHidden = true
    }
}
