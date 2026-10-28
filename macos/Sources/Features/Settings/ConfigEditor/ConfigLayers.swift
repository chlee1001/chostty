import Foundation

/// The files that decide a key's effective value besides the edited one.
///
/// Mirrors the load order in `src/config/Config.zig`: the theme is loaded
/// first and the user's config replayed on top of it (`loadTheme`), and
/// `config-file` includes are loaded after the main file
/// (`loadRecursiveFiles`). So for a single-value key an include beats the
/// main file, and both beat the theme.
struct ConfigLayers {
    struct Include: Equatable {
        let path: String
        let document: ConfigDocument
    }

    struct Theme: Equatable {
        let name: String
        let document: ConfigDocument
    }

    enum Source: Equatable {
        case file
        case include(path: String)
        case theme(name: String)
    }

    struct Effective: Equatable {
        let value: String
        let source: Source
    }

    private(set) var includes: [Include] = []
    private(set) var theme: Theme?
    private(set) var roots: [(document: ConfigDocument, path: String)] = []
    /// An include existed but could not be read as UTF-8 text; missing and
    /// unreadable includes are skipped silently, as Ghostty skips them.
    private(set) var hasUndecodableInclude = false
    private(set) var hasEmptyConfigFile = false
    private(set) var themeValue: String?
    private(set) var themeLoadFailed = false

    init() {}

    /// Resolve the includes and theme reachable from `main`, which lives at
    /// `mainPath`. Unreadable or missing files are skipped: the reload's
    /// error window reports them, the editor only needs what loads.
    init(
        main: ConfigDocument,
        mainPath: String,
        prefersDark: Bool,
        themeDirectories: [(url: URL, isUser: Bool)]
    ) {
        self.init(
            roots: [(document: main, path: mainPath)],
            prefersDark: prefersDark,
            themeDirectories: themeDirectories
        )
    }

    /// Whether a read failed because the file is absent or not permitted,
    /// which Ghostty skips silently. Foundation reports a missing file read
    /// as `fileReadNoSuchFile`; `fileNoSuchFile` is accepted for callers
    /// that throw the generic code.
    static func isMissingOrUnreadable(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == CocoaError.fileReadNoSuchFile.rawValue
            || error.code == CocoaError.fileNoSuchFile.rawValue
            || error.code == CocoaError.fileReadNoPermission.rawValue
    }

    init(
        roots: [(document: ConfigDocument, path: String)],
        prefersDark: Bool,
        themeDirectories: [(url: URL, isUser: Bool)],
        readFile: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        fileExists: (URL) -> Bool = ThemeCatalog.isRegularFile
    ) {
        self.roots = roots
        // Breadth-first like Ghostty's growing `config-file` list; nested
        // includes resolve relative to the file that names them.
        var queue: [(String, String)] = []
        var loaded: Set<String> = []
        for root in roots {
            let normalized = (root.path as NSString).standardizingPath
            loaded.insert(normalized)
            let directory = (root.path as NSString).deletingLastPathComponent
            queue += root.document.values(forKey: "config-file").map { ($0, directory) }
        }
        var index = 0
        while index < queue.count {
            let (raw, base) = queue[index]
            index += 1
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hasEmptyConfigFile = true
                continue
            }
            guard let path = Self.expandPath(raw, relativeTo: base), loaded.insert(path).inserted else { continue }
            let text: String
            do {
                text = try readFile(path)
            } catch let error where Self.isMissingOrUnreadable(error) {
                continue
            } catch {
                hasUndecodableInclude = true
                continue
            }
            let document = ConfigDocument(text: text)
            includes.append(Include(path: path, document: document))
            let directory = (path as NSString).deletingLastPathComponent
            queue += document.values(forKey: "config-file").map { ($0, directory) }
        }

        themeValue = (roots.map(\.document) + includes.map(\.document)).reversed().lazy.compactMap { $0.value(forKey: "theme") }.first
        if let themeValue,
           let selection = ThemeCatalog.Selection(themeValue) {
            let name = selection.name(prefersDark: prefersDark)
            if let url = ThemeCatalog.resolve(name, in: themeDirectories, fileExists: fileExists),
               let text = try? readFile(url.path) {
                theme = Theme(name: name, document: ConfigDocument(text: text))
            } else {
                themeLoadFailed = true
            }
        } else if themeValue != nil {
            themeLoadFailed = true
        }
    }

    /// The value Ghostty ends up with for a single-value `key`, or `nil`
    /// when nothing sets it and the built-in default applies.
    func effective(_ key: String, main: ConfigDocument) -> Effective? {
        for include in includes.reversed() {
            if let value = include.document.value(forKey: key) {
                return Effective(value: value, source: .include(path: include.path))
            }
        }
        if let value = main.value(forKey: key) {
            return Effective(value: value, source: .file)
        }
        if let theme, let value = theme.document.value(forKey: key) {
            return Effective(value: value, source: .theme(name: theme.name))
        }
        return nil
    }

    /// The last include that sets `key`: it overrides whatever the main
    /// file says.
    func overridingInclude(for key: String) -> Include? {
        includes.last { !$0.document.values(forKey: key).isEmpty }
    }

    /// Entries a repeatable `key` gets from the theme and includes on top
    /// of the main file's own.
    func externalValueCount(for key: String) -> (theme: Int, includes: Int) {
        (
            theme?.document.values(forKey: key).count ?? 0,
            includes.reduce(0) { $0 + $1.document.values(forKey: key).count }
        )
    }

    /// Expand a `config-file` value the way `src/config/path.zig` does: an
    /// optional `?` prefix and surrounding quotes are dropped, `~/` is the
    /// home directory, and relative paths resolve against `base`.
    static func expandPath(_ raw: String, relativeTo base: String) -> String? {
        var value = raw
        if value.hasPrefix("?") { value.removeFirst() }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("~/") {
            value = NSHomeDirectory() + value.dropFirst()
        } else if !value.hasPrefix("/") {
            value = (base as NSString).appendingPathComponent(value)
        }
        return (value as NSString).standardizingPath
    }
}
