import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the `open_config` action (menu or keybind) should present
    /// the GUI configuration editor. `userInfo` carries the config file
    /// path under `ConfigEditorController.pathKey`.
    static let chosttyPresentConfigEditor = Notification.Name("chosttyPresentConfigEditor")
}

/// The window hosting the GUI configuration editor.
///
/// Presented from Preferences… (⌘,) and the `open_config` action. Edits the
/// file `ghostty_config_open_path()` resolves (see `src/config/edit.zig`):
/// on macOS that is the first non-empty of App Support, legacy App Support,
/// `~/.config/ghostty/config.ghostty`, legacy `~/.config/ghostty/config`.
final class ConfigEditorController: NSWindowController, NSWindowDelegate {
    static let shared = ConfigEditorController()

    static let pathKey = "path"

    private var model: ConfigEditorModel?
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Configuration"
        window.center()
        window.setFrameAutosaveName("ConfigEditorWindow")
        super.init(window: window)
        window.delegate = self

        // Singleton for the app's lifetime, so the observer is never removed.
        observer = NotificationCenter.default.addObserver(
            forName: .chosttyPresentConfigEditor,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let path = notification.userInfo?[Self.pathKey] as? String else { return }
            self?.show(configPath: path)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show the editor for the config file at `configPath`.
    ///
    /// A model with unsaved edits is kept as-is when the path is unchanged
    /// so reopening the window never discards in-flight work; a clean one
    /// re-reads the file so edits made elsewhere are never shown stale.
    func show(configPath: String) {
        if let model, model.path == configPath {
            model.reloadIfClean()
        } else {
            loadModel(path: configPath)
        }
        guard model != nil else { return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadModel(path: String) {
        let contents: String
        do {
            contents = try ConfigEditorModel.readContents(at: path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Open Configuration"
            alert.informativeText = "\(path)\n\n\(error.localizedDescription)"
            alert.runModal()
            return
        }

        let prefersDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let model = ConfigEditorModel(path: path, contents: contents, prefersDark: prefersDark)
        self.model = model
        window?.contentView = NSHostingView(rootView: ConfigEditorView(model: model))
        Task { await model.loadReference() }
    }

    // MARK: NSWindowDelegate

    /// Returning from "Edit in External Editor" lands here.
    func windowDidBecomeKey(_ notification: Notification) {
        model?.reloadIfClean()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "Save Changes?"
        alert.informativeText = "The configuration has unsaved changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try model.save()
            } catch ConfigEditorModel.SaveError.changedOnDisk {
                // Never overwrite external edits from a close prompt; keep
                // the window open so the editor's conflict choice applies.
                let conflict = NSAlert()
                conflict.messageText = "Configuration Changed on Disk"
                conflict.informativeText = "Use Save & Apply to choose between overwriting it and reloading it."
                conflict.runModal()
                return false
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Couldn’t Save"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.runModal()
                return false
            }
            // Mirror Save & Apply: persisting without reloading would leave
            // the app disagreeing with the file.
            (NSApplication.shared.delegate as? AppDelegate)?.reloadConfig(nil)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}
