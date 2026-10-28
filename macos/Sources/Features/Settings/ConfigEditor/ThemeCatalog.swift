import Foundation

/// One theme file as the gallery shows it: the colors needed for a preview
/// card, read with ``ConfigDocument`` since theme files are config files.
struct ThemeInfo: Identifiable, Equatable {
    var id: String { name }

    let name: String
    let url: URL
    /// Found in the user's theme directory rather than the app bundle.
    let isUser: Bool
    let background: String?
    let foreground: String?
    let cursor: String?
    /// `palette` entries keyed by index, e.g. `1 → "#cc6666"`.
    let palette: [Int: String]

    /// Classified by background luminance. A theme without a background
    /// counts as dark: Ghostty's default background is dark.
    var isDark: Bool {
        guard let background, let rgb = ThemeCatalog.rgb(background) else { return true }
        return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b < 0.5
    }

    init(name: String, url: URL, isUser: Bool, document: ConfigDocument) {
        self.name = name
        self.url = url
        self.isUser = isUser
        background = document.value(forKey: "background")
        foreground = document.value(forKey: "foreground")
        cursor = document.value(forKey: "cursor-color")
        var palette: [Int: String] = [:]
        for entry in document.values(forKey: "palette") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            palette[index] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        self.palette = palette
    }
}

/// Theme discovery and the `theme` value format, mirroring
/// `src/config/theme.zig` and `Config.Theme`.
enum ThemeCatalog {
    /// A `theme` value: one name for both appearances, or a
    /// `light:NAME,dark:NAME` pair.
    struct Selection: Equatable {
        var light: String
        var dark: String

        var isPair: Bool { light != dark }

        /// Parse like `Theme.parseCLI`: a value containing `,`, `:` or `=`
        /// must be a `light:NAME,dark:NAME` pair (so `light=A` fails here
        /// as it does in Ghostty); anything else is a single name.
        init?(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.contains(where: { $0 == "," || $0 == ":" || $0 == "=" }) else {
                light = trimmed
                dark = trimmed
                return
            }
            var fields: [String: String] = [:]
            for part in trimmed.split(separator: ",") {
                guard let sep = part.firstIndex(of: ":") else { return nil }
                let key = part[..<sep].trimmingCharacters(in: .whitespaces)
                let name = part[part.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                fields[key] = name
            }
            guard let light = fields["light"], let dark = fields["dark"],
                  !light.isEmpty, !dark.isEmpty
            else { return nil }
            self.light = light
            self.dark = dark
        }

        init(light: String, dark: String) {
            self.light = light
            self.dark = dark
        }

        /// The config value: a bare name when both sides match.
        var value: String {
            isPair ? "light:\(light),dark:\(dark)" : light
        }

        func name(prefersDark: Bool) -> String {
            prefersDark ? dark : light
        }
    }

    /// Search directories in priority order, as `theme.zig`'s `Location`:
    /// the user's `$XDG_CONFIG_HOME/ghostty/themes` (default
    /// `~/.config/ghostty/themes`), then the bundled resources.
    static func directories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> [(url: URL, isUser: Bool)] {
        var result: [(URL, Bool)] = [
            (ConfigHome.directory(environment: environment).appendingPathComponent("ghostty/themes"), true),
        ]
        if let resources = bundle.resourceURL {
            result.append((resources.appendingPathComponent("ghostty/themes"), false))
        }
        return result
    }

    /// Whether `url` names an existing file that is not a directory.
    static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// The file a theme name loads from: an absolute path as-is, otherwise
    /// the first directory containing it. Names with path separators are
    /// rejected the way Ghostty rejects them.
    static func resolve(
        _ name: String,
        in directories: [(url: URL, isUser: Bool)],
        fileExists: (URL) -> Bool = isRegularFile
    ) -> URL? {
        if name.hasPrefix("/") {
            let url = URL(fileURLWithPath: name)
            return fileExists(url) ? url : nil
        }
        guard !name.contains("/") else { return nil }
        for directory in directories {
            let url = directory.url.appendingPathComponent(name)
            if fileExists(url) {
                return url
            }
        }
        return nil
    }

    /// Every theme in `directories`, sorted by name. A user theme shadows a
    /// bundled one with the same name, as it does when Ghostty loads it.
    static func load(from directories: [(url: URL, isUser: Bool)]) -> [ThemeInfo] {
        var seen: Set<String> = []
        var themes: [ThemeInfo] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.path)) ?? []
            for name in names where !name.hasPrefix(".") && !seen.contains(name) {
                let url = directory.url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                seen.insert(name)
                themes.append(ThemeInfo(
                    name: name,
                    url: url,
                    isUser: directory.isUser,
                    document: ConfigDocument(text: text)
                ))
            }
        }
        return themes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `#rgb` / `#rrggbb` (with or without `#`) as 0–1 components.
    static func rgb(_ raw: String) -> (r: Double, g: Double, b: Double)? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()
        case 6: expanded = hex
        default: return nil
        }
        guard let value = UInt32(expanded, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
