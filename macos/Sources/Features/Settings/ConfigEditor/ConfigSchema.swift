import Foundation

/// Editor metadata for one Ghostty config key.
///
/// ``ConfigSchema`` curates the common keys with type-specific controls;
/// ``ConfigReference`` derives a generic row for every other key. Keys,
/// kinds and defaults mirror `src/config/Config.zig`, which
/// `ConfigSchemaTests` checks through libghostty's parser.
struct ConfigOption: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable {
        case general
        case window
        case font
        case colors
        case cursor
        case behavior

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: "General"
            case .window: "Window"
            case .font: "Font"
            case .colors: "Colors"
            case .cursor: "Cursor & Mouse"
            case .behavior: "Behavior"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .window: "macwindow"
            case .font: "textformat"
            case .colors: "paintpalette"
            case .cursor: "cursorarrow.click"
            case .behavior: "switch.2"
            }
        }
    }

    /// A keyword value a color option accepts in place of a color.
    struct Special: Equatable {
        let value: String
        let label: String
    }

    enum Kind: Equatable {
        /// `true` / `false`.
        case bool
        /// `true` / `false`, plus Default (leave unset), for `?bool` keys
        /// whose unset state behaves differently from both.
        case optionalBool
        /// Free-form single-line value.
        case text
        /// Decimal number, e.g. `font-size`.
        case number
        /// Float 0.0–1.0 shown as a slider.
        case opacity
        /// One of a fixed set of literal values.
        case choice([String])
        /// One of a fixed set of literal values, plus Default (leave unset).
        case optionalChoice([String])
        /// A color: `#rgb`, `#rrggbb`, a named color, or one of `special`.
        case color(special: [Special])
        /// Repeatable key: one value per line.
        case list(placeholder: String)
        /// The `theme` key: a name or `light:…,dark:…` pair, picked from
        /// the theme gallery.
        case theme
    }

    var id: String { key }

    let key: String
    let label: String
    let doc: String
    /// `nil` for keys outside the curated schema, reachable only through
    /// All Settings and search.
    let category: Category?
    let kind: Kind
    /// The default rendered as an empty control's placeholder. `nil` when
    /// the default is platform-conditional or unresolved at config load.
    let defaultValue: String?
}

enum ConfigSchema {
    static let options: [ConfigOption] = [
        // MARK: General
        .init(
            key: "command",
            label: "Command",
            doc: "Command to run in new surfaces instead of the default shell.",
            category: .general,
            kind: .text,
            defaultValue: nil
        ),
        .init(
            key: "shell-integration",
            label: "Shell Integration",
            doc: "Shell integration injection scheme.",
            category: .general,
            kind: .choice(["detect", "none", "bash", "elvish", "fish", "nushell", "zsh"]),
            defaultValue: "detect"
        ),
        .init(
            key: "auto-update",
            label: "Auto Update",
            doc: "Update behavior: `check` reports, `download` also downloads. Chostty ships stable updates only.",
            category: .general,
            kind: .optionalChoice(["off", "check", "download"]),
            defaultValue: nil
        ),

        // MARK: Window
        .init(
            key: "window-decoration",
            label: "Window Decorations",
            doc: "Title bar and decorations. `false` is an alias for `none`.",
            category: .window,
            kind: .choice(["auto", "client", "server", "none"]),
            defaultValue: "auto"
        ),
        .init(
            key: "window-theme",
            label: "Window Theme",
            doc: "Window color scheme: follow Ghostty, the system, or force light/dark.",
            category: .window,
            kind: .choice(["auto", "system", "light", "dark", "ghostty"]),
            defaultValue: "auto"
        ),
        .init(
            key: "window-padding-x",
            label: "Horizontal Padding",
            doc: "Left/right window padding: `N` or `A,B` (left,right).",
            category: .window,
            kind: .text,
            defaultValue: "2"
        ),
        .init(
            key: "window-padding-y",
            label: "Vertical Padding",
            doc: "Top/bottom window padding: `N` or `A,B` (top,bottom).",
            category: .window,
            kind: .text,
            defaultValue: "2"
        ),
        .init(
            key: "background-opacity",
            label: "Background Opacity",
            doc: "Terminal background opacity, 0.0 to 1.0.",
            category: .window,
            kind: .opacity,
            defaultValue: "1"
        ),
        .init(
            key: "background-blur",
            label: "Background Blur",
            doc: "Blur behind a transparent background. A number 1–100 is a custom radius.",
            category: .window,
            kind: .choice(["false", "true", "macos-glass-regular", "macos-glass-clear"]),
            defaultValue: "false"
        ),
        .init(
            key: "confirm-close-surface",
            label: "Confirm Close",
            doc: "Confirm closing a surface whose process is still running.",
            category: .window,
            kind: .choice(["false", "true", "always"]),
            defaultValue: "true"
        ),
        .init(
            key: "quit-after-last-window-closed",
            label: "Quit After Last Window",
            doc: "Quit Chostty when the last window closes.",
            category: .window,
            kind: .bool,
            defaultValue: "false"
        ),
        .init(
            key: "resize-overlay",
            label: "Resize Overlay",
            doc: "When to show the surface size overlay while resizing.",
            category: .window,
            kind: .choice(["always", "never", "after-first"]),
            defaultValue: "after-first"
        ),

        // MARK: Font
        .init(
            key: "font-family",
            label: "Font Families",
            doc: "Preferred font families in priority order, one per line.",
            category: .font,
            kind: .list(placeholder: "JetBrainsMono Nerd Font"),
            defaultValue: nil
        ),
        .init(
            key: "font-size",
            label: "Font Size",
            doc: "Font size in points.",
            category: .font,
            kind: .number,
            defaultValue: "13"
        ),
        .init(
            key: "font-thicken",
            label: "Thicken Font",
            doc: "Thicken font rendering (macOS font smoothing).",
            category: .font,
            kind: .bool,
            defaultValue: "false"
        ),
        .init(
            key: "font-feature",
            label: "Font Features",
            doc: "OpenType features like `calt` or `ss01`, one per line. Prefix `-` to disable.",
            category: .font,
            kind: .list(placeholder: "ss01"),
            defaultValue: nil
        ),

        // MARK: Colors
        .init(
            key: "theme",
            label: "Theme",
            doc: "A theme name, or different themes per appearance like `light:Builtin Light,dark:Builtin Dark`. Settings in this file override the theme.",
            category: .colors,
            kind: .theme,
            defaultValue: nil
        ),
        .init(
            key: "background",
            label: "Background",
            doc: "Background color: `#rrggbb` or a named color like `blue`.",
            category: .colors,
            kind: .color(special: []),
            defaultValue: "#282c34"
        ),
        .init(
            key: "foreground",
            label: "Foreground",
            doc: "Text color.",
            category: .colors,
            kind: .color(special: []),
            defaultValue: "#ffffff"
        ),
        .init(
            key: "cursor-color",
            label: "Cursor Color",
            doc: "Cursor color.",
            category: .colors,
            kind: .color(special: [.init(value: "cell-foreground", label: "Cell foreground")]),
            defaultValue: nil
        ),
        .init(
            key: "cursor-text",
            label: "Cursor Text",
            doc: "Color of text under a block cursor.",
            category: .colors,
            kind: .color(special: [.init(value: "cell-background", label: "Cell background")]),
            defaultValue: nil
        ),
        .init(
            key: "selection-background",
            label: "Selection Background",
            doc: "Selection background color.",
            category: .colors,
            kind: .color(special: [.init(value: "cell-foreground", label: "Cell foreground")]),
            defaultValue: nil
        ),
        .init(
            key: "selection-foreground",
            label: "Selection Foreground",
            doc: "Selected text color.",
            category: .colors,
            kind: .color(special: [.init(value: "cell-background", label: "Cell background")]),
            defaultValue: nil
        ),
        .init(
            key: "palette",
            label: "256-Color Palette",
            doc: "Palette overrides as `index=color`, one per line (e.g. `0=#282c34`).",
            category: .colors,
            kind: .list(placeholder: "0=#282c34"),
            defaultValue: nil
        ),

        // MARK: Cursor & Mouse
        .init(
            key: "cursor-style",
            label: "Cursor Style",
            doc: "Cursor shape.",
            category: .cursor,
            kind: .choice(["block", "bar", "underline", "block_hollow"]),
            defaultValue: "block"
        ),
        .init(
            key: "cursor-style-blink",
            label: "Cursor Blinking",
            doc: "Whether the cursor blinks. Default blinks and lets programs toggle it with DEC mode 12; On and Off ignore that mode.",
            category: .cursor,
            kind: .optionalBool,
            defaultValue: nil
        ),
        .init(
            key: "cursor-opacity",
            label: "Cursor Opacity",
            doc: "Cursor opacity, 0.0 to 1.0.",
            category: .cursor,
            kind: .opacity,
            defaultValue: "1"
        ),
        .init(
            key: "mouse-hide-while-typing",
            label: "Hide Mouse While Typing",
            doc: "Hide the mouse cursor while typing.",
            category: .cursor,
            kind: .bool,
            defaultValue: "false"
        ),
        .init(
            key: "mouse-scroll-multiplier",
            label: "Scroll Multiplier",
            doc: "Scroll distance multiplier: one number, or per device type like `precision:0.1,discrete:3`. Default 1 for trackpads, 3 for wheels.",
            category: .cursor,
            kind: .text,
            defaultValue: nil
        ),

        // MARK: Behavior
        .init(
            key: "copy-on-select",
            label: "Copy On Select",
            doc: "`true` copies selections to the selection clipboard used by middle-click paste; `clipboard` also copies to the system clipboard.",
            category: .behavior,
            kind: .choice(["false", "true", "clipboard"]),
            defaultValue: "true"
        ),
        .init(
            key: "clipboard-read",
            label: "Clipboard Read",
            doc: "What OSC 52 (clipboard read) may do.",
            category: .behavior,
            kind: .choice(["ask", "allow", "deny"]),
            defaultValue: "ask"
        ),
        .init(
            key: "clipboard-write",
            label: "Clipboard Write",
            doc: "What OSC 52 (clipboard write) may do.",
            category: .behavior,
            kind: .choice(["ask", "allow", "deny"]),
            defaultValue: "allow"
        ),
        .init(
            key: "keybind",
            label: "Keybindings",
            doc: "Keybindings as `trigger=action`, one per line (e.g. `cmd+d=new_split:right`).",
            category: .behavior,
            kind: .list(placeholder: "cmd+d=new_split:right"),
            defaultValue: nil
        ),
    ]
}
