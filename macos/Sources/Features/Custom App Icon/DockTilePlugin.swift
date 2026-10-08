import AppKit

class DockTilePlugin: NSObject, NSDockTilePlugIn {
    // WARNING: An instance of this class is alive as long as Ghostty's icon is
    // in the doc (running or not!), so keep any state and processing to a
    // minimum to respect resource usage.

    private let pluginBundle = Bundle(for: DockTilePlugin.self)

    // Separate defaults based on debug vs release builds so we can test icons
    // without messing up releases.
    // The legacy domains cover a Dock tile drawn before the renamed app has
    // launched once and run `LegacyBundleMigration`.
    #if DEBUG
    private let primaryDefaults = UserDefaults(suiteName: "kr.co.devch.chostty.debug")
    private let legacyDefaults = ["com.chostty.app.debug", "com.mitchellh.ghostty.debug"]
        .compactMap(UserDefaults.init(suiteName:))
    #else
    private let primaryDefaults = UserDefaults(suiteName: "kr.co.devch.chostty")
    private let legacyDefaults = ["com.chostty.app", "com.mitchellh.ghostty"]
        .compactMap(UserDefaults.init(suiteName:))
    #endif

    private var iconChangeObserver: Any?

    /// The primary NSDockTilePlugin function.
    func setDockTile(_ dockTile: NSDockTile?) {
        // If no dock tile or no access to Ghostty defaults, we can't do anything.
        guard let dockTile else {
            iconChangeObserver = nil
            return
        }

        // Try to restore the previous icon on launch.
        iconDidChange(currentAppIcon(), dockTile: dockTile)

        // Setup a new observer for when the icon changes so we can update. This message
        // is sent by the primary Ghostty app.
        iconChangeObserver = DistributedNotificationCenter
            .default()
            .publisher(for: .ghosttyIconDidChange)
            .map { [weak self] _ in self?.currentAppIcon() }
            .receive(on: DispatchQueue.global())
            .sink { [weak self] newIcon in self?.iconDidChange(newIcon, dockTile: dockTile) }
    }

    /// Read the configured app icon, preferring the Chostty defaults domain
    /// and falling back to the legacy domains in order.
    private func currentAppIcon() -> AppIcon? {
        primaryDefaults.flatMap { $0.appIcon } ?? legacyDefaults.lazy.compactMap(\.appIcon).first
    }

    private func iconDidChange(_ newIcon: AppIcon?, dockTile: NSDockTile) {
        guard let appIcon = newIcon?.image(in: pluginBundle) else {
            resetIcon(dockTile: dockTile)
            return
        }

        dockTile.setIcon(appIcon)
    }

    /// Reset the application icon and dock tile icon to the default.
    private func resetIcon(dockTile: NSDockTile) {
        let appIcon: NSImage?
        if #available(macOS 26.0, *) {
            #if DEBUG
            // Use the `Blueprint` icon to distinguish Debug from Release builds.
            appIcon = pluginBundle.image(forResource: "BlueprintImage")!
            #else
            // Reset to Chostty.icon
            appIcon = nil
            #endif
        } else {
            // Use the bundled icon to keep the corner radius consistent with pre-Tahoe apps.
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
        }
        dockTile.setIcon(appIcon)
    }
}

private extension NSDockTile {
    func setIcon(_ newIcon: NSImage?) {
        // Update the Dock tile on the main thread.
        DispatchQueue.main.async {
            guard let newIcon else {
                self.contentView = nil
                self.display()
                return
            }
            let iconView = NSImageView(frame: CGRect(origin: .zero, size: self.size))
            iconView.wantsLayer = true
            iconView.image = newIcon
            self.contentView = iconView
            self.display()
        }
    }
}

// This is required because of the DispatchQueue call above. This doesn't
// feel right but I don't know a better way to solve this.
extension NSDockTile: @unchecked @retroactive Sendable {}
