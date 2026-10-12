import Foundation

/// One key from `+show-config --default --docs`.
struct ConfigReferenceEntry: Equatable {
    let key: String
    /// The full upstream documentation (Markdown).
    let doc: String
    /// Default values; several for repeatable keys like `keybind`.
    let defaults: [String]

    /// The first paragraph, unwrapped, for a row's inline help.
    var summary: String {
        let paragraph = doc.components(separatedBy: "\n\n").first ?? doc
        return paragraph.replacingOccurrences(of: "\n", with: " ")
    }
}

/// The complete key catalog, read from this build's own
/// `+show-config --default --docs`. Every key the binary accepts, with its
/// docs and defaults, comes from the binary itself, so this list cannot
/// drift from `src/config/Config.zig` the way a hand-written copy would.
/// The curated ``ConfigSchema`` only adds richer controls for some keys.
enum ConfigReference {
    /// Keys whose field type accumulates one value per line
    /// (`Repeatable*`, `Keybinds`, `Palette`, …) in `Config.zig`.
    /// `ConfigReferenceSourceTests` checks this against the source.
    static let repeatableKeys: Set<String> = [
        "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic",
        "font-feature", "font-variation", "font-variation-bold", "font-variation-italic",
        "font-variation-bold-italic", "font-codepoint-map", "clipboard-codepoint-map",
        "palette", "env", "input", "link", "keybind", "key-remap", "config-file",
        "command-palette-entry", "custom-shader", "gtk-custom-css",
    ]

    /// Keys whose field type is `bool` in `Config.zig`. A `true`/`false`
    /// default alone is not enough: enums like `copy-on-select` and
    /// `background-blur` also default to `true`/`false` but accept more.
    /// `ConfigReferenceSourceTests` checks this against the source.
    static let boolKeys: Set<String> = [
        "font-thicken", "background-image-repeat", "selection-clear-on-typing",
        "selection-clear-on-copy", "palette-generate", "palette-harmonious",
        "cursor-click-to-move", "mouse-hide-while-typing", "mouse-reporting",
        "background-opacity-cells", "wait-after-command", "scrollback-compression",
        "link-url", "maximize", "window-vsync", "window-inherit-working-directory",
        "tab-inherit-working-directory", "split-inherit-working-directory",
        "window-inherit-font-size", "window-step-resize", "focus-follows-mouse",
        "clipboard-trim-trailing-spaces", "clipboard-paste-protection",
        "clipboard-paste-bracketed-safe", "title-report", "config-default-files",
        "quit-after-last-window-closed", "initial-window", "quick-terminal-autohide",
        "vt-kam-allowed", "macos-session-persistence", "macos-window-shadow",
        "macos-auto-secure-input", "macos-secure-input-indication", "macos-applescript",
        "linux-cgroup-hard-fail", "gtk-opengl-debug", "gtk-titlebar",
        "gtk-titlebar-hide-when-maximized", "gtk-wide-tabs", "gtk-horizontal-tab-scroll",
        "desktop-notifications", "progress-style",
    ]

    /// Run `+show-config --default --docs` on the app's own executable.
    /// Returns an empty catalog when that fails; the editor then shows only
    /// the curated keys.
    static func load(executable: URL? = Bundle.main.executableURL) async -> [ConfigReferenceEntry] {
        guard let executable else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["+show-config", "--default", "--docs", "--no-pager"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            // Drain before waiting: the output is larger than a pipe buffer.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return parse(String(bytes: data, encoding: .utf8) ?? "")
        }.value
    }

    /// Parse `+show-config --default --docs` output: each key is a block of
    /// `# ` doc lines followed by one or more `key = value` lines.
    static func parse(_ output: String) -> [ConfigReferenceEntry] {
        var entries: [ConfigReferenceEntry] = []
        var docLines: [String] = []
        var key: String?
        var doc = ""
        var defaults: [String] = []

        func flush() {
            guard let current = key else { return }
            // Grouped keys (`font-family-bold` after `font-family`) are
            // documented once, on the first key of the group.
            let resolved = doc.isEmpty ? (entries.last?.doc ?? "") : doc
            entries.append(ConfigReferenceEntry(key: current, doc: resolved, defaults: defaults))
            key = nil
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                flush()
                docLines.append(line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line.dropFirst()))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else {
                continue
            }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if name != key {
                flush()
                key = name
                doc = docLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                defaults = []
                docLines = []
            }
            if !value.isEmpty { defaults.append(value) }
        }
        flush()
        return entries
    }

    /// An editor row for a key the curated schema doesn't cover: a list for
    /// repeatable keys, a switch for `bool`, otherwise text checked live by
    /// the parser.
    static func option(for entry: ConfigReferenceEntry) -> ConfigOption {
        let kind: ConfigOption.Kind
        let defaultValue: String?
        if repeatableKeys.contains(entry.key) {
            kind = .list(placeholder: entry.defaults.first ?? "")
            defaultValue = nil
        } else {
            kind = boolKeys.contains(entry.key) ? .bool : .text
            defaultValue = entry.defaults.last
        }
        return ConfigOption(
            key: entry.key,
            label: label(for: entry.key),
            doc: entry.summary,
            category: nil,
            kind: kind,
            defaultValue: defaultValue
        )
    }

    private static let acronyms: [String: String] = [
        "macos": "macOS", "gtk": "GTK", "osc": "OSC", "ui": "UI", "id": "ID",
        "url": "URL", "ime": "IME", "x11": "X11", "vt": "VT", "kam": "KAM",
        "cgroup": "cgroup", "dpi": "DPI",
    ]

    /// `window-padding-x` → `Window Padding X`.
    static func label(for key: String) -> String {
        key.split(separator: "-").map { word in
            acronyms[String(word)] ?? word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
