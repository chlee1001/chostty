import Foundation

/// Observable state behind the configuration editor: one
/// ``ConfigDocument`` loaded from the user's config file plus dirty
/// tracking and live parser diagnostics. Saving writes the document back
/// atomically; the caller is responsible for reloading the app
/// configuration afterwards.
@MainActor
final class ConfigEditorModel: ObservableObject {
    enum SaveError: LocalizedError {
        /// The file on disk no longer matches what the editor loaded, so
        /// saving would silently discard someone else's edits.
        case changedOnDisk

        var errorDescription: String? {
            "The configuration file changed on disk after the editor loaded it."
        }
    }

    @Published private(set) var document: ConfigDocument {
        didSet {
            issues = ConfigValidator.issues(in: document)
            // Only `config-file` and `theme` decide which other files load.
            if document.values(forKey: "config-file") != oldValue.values(forKey: "config-file")
                || document.values(forKey: "theme") != oldValue.values(forKey: "theme") {
                refreshLayers()
            }
        }
    }
    @Published private(set) var issues: [ConfigIssue]
    /// Includes and theme behind the effective values.
    @Published private(set) var layers = ConfigLayers()
    /// Every key the binary knows (curated rows first-class), or only the
    /// curated schema until ``loadReference()`` finishes or if it fails.
    @Published private(set) var allOptions: [ConfigOption] = ConfigSchema.options
    /// Full upstream docs by key, from the same catalog.
    @Published private(set) var referenceDocs: [String: String] = [:]
    @Published var searchText: String = ""
    @Published private(set) var isDirty = false

    let path: String

    /// Which side of a `light:…,dark:…` theme pair applies, as Ghostty's
    /// conditional theme state does for the current appearance.
    let prefersDark: Bool
    let themeDirectories: [(url: URL, isUser: Bool)]

    /// The file contents as last read or written, for detecting edits made
    /// outside the editor.
    private var diskText: String

    init(
        path: String,
        contents: String,
        prefersDark: Bool = false,
        themeDirectories: [(url: URL, isUser: Bool)] = ThemeCatalog.directories()
    ) {
        self.path = path
        self.prefersDark = prefersDark
        self.themeDirectories = themeDirectories
        let document = ConfigDocument(text: contents)
        self.document = document
        self.issues = ConfigValidator.issues(in: document)
        self.diskText = contents
        refreshLayers()
    }

    // MARK: Layers

    /// Re-read includes and the theme. Runs when their names change, and
    /// when the window regains focus since the files may have been edited.
    func refreshLayers() {
        layers = ConfigLayers(
            main: document,
            mainPath: path,
            prefersDark: prefersDark,
            themeDirectories: themeDirectories
        )
    }

    /// What Ghostty ends up with for a single-value option, or `nil` when
    /// the built-in default applies.
    func effective(_ option: ConfigOption) -> ConfigLayers.Effective? {
        layers.effective(option.key, main: document)
    }

    /// The value a control shows: the file's, else what an include or the
    /// theme sets, else the default.
    func displayedValue(_ option: ConfigOption) -> String? {
        effective(option)?.value ?? option.defaultValue
    }

    /// An include that overrides the value this file sets explicitly, so
    /// editing the row here would have no effect.
    func overridingInclude(_ option: ConfigOption) -> ConfigLayers.Include? {
        guard isExplicit(option) else { return nil }
        return layers.overridingInclude(for: option.key)
    }

    // MARK: Reference

    /// Load the full key catalog from the binary. Curated options keep
    /// their richer controls; every other key gets a generic row.
    func loadReference() async {
        let entries = await ConfigReference.load()
        guard !entries.isEmpty else { return }
        apply(reference: entries)
    }

    func apply(reference entries: [ConfigReferenceEntry]) {
        let curated = Dictionary(uniqueKeysWithValues: ConfigSchema.options.map { ($0.key, $0) })
        let listed = Set(entries.map(\.key))
        allOptions = entries.map { curated[$0.key] ?? ConfigReference.option(for: $0) }
            + ConfigSchema.options.filter { !listed.contains($0.key) }
        referenceDocs = Dictionary(entries.map { ($0.key, $0.doc) }) { first, _ in first }
    }

    // MARK: Values

    func value(_ option: ConfigOption) -> String? {
        document.value(forKey: option.key)
    }

    func values(_ option: ConfigOption) -> [String] {
        document.values(forKey: option.key)
    }

    /// True when the file sets the key explicitly (the row shows a Reset
    /// button and a modified marker).
    func isExplicit(_ option: ConfigOption) -> Bool {
        !document.values(forKey: option.key).isEmpty
    }

    /// Parser problems on this option's lines.
    func issues(for option: ConfigOption) -> [ConfigIssue] {
        issues.filter { $0.key == option.key }
    }

    /// Set a single value. Clearing the value removes the key: an empty
    /// field means "use the default", not a blank `key =` line.
    func setValue(_ value: String, for option: ConfigOption) {
        if ConfigDocument.normalizedValue(value).isEmpty {
            reset(option)
        } else {
            mutate { $0.setValue(value, forKey: option.key) }
        }
    }

    func setValues(_ values: [String], for option: ConfigOption) {
        mutate { $0.setValues(values, forKey: option.key) }
    }

    func reset(_ option: ConfigOption) {
        mutate { $0.removeValues(forKey: option.key) }
    }

    private func mutate(_ body: (inout ConfigDocument) -> Void) {
        var next = document
        body(&next)
        guard next != document else { return }
        document = next
        isDirty = true
    }

    // MARK: Filtering

    func options(in category: ConfigOption.Category) -> [ConfigOption] {
        ConfigSchema.options.filter { $0.category == category }
    }

    /// Options matching `searchText` across every known key, ranked so a
    /// key or label hit comes before a doc-only hit. An empty search means
    /// no active filter.
    var searchResults: [ConfigOption] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let named = allOptions.filter {
            $0.key.contains(needle) || $0.label.lowercased().contains(needle)
        }
        let namedKeys = Set(named.map(\.key))
        let documented = allOptions.filter {
            !namedKeys.contains($0.key) && $0.doc.lowercased().contains(needle)
        }
        return named + documented
    }

    /// Every key the file sets explicitly, for All Settings' modified count.
    var explicitCount: Int {
        allOptions.filter { isExplicit($0) }.count
    }

    /// Number of options in `category` the file sets explicitly, for the
    /// sidebar's modified badge.
    func explicitCount(in category: ConfigOption.Category) -> Int {
        options(in: category).filter { isExplicit($0) }.count
    }

    // MARK: Persistence

    /// The file contents, with a missing file reading as empty — the same
    /// state the editor opens a not-yet-created config in.
    static func readContents(at path: String) throws -> String {
        do {
            return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }

    /// Write the document back to `path`, creating the file if needed.
    ///
    /// Throws ``SaveError/changedOnDisk`` when the file was edited outside
    /// the editor since it was loaded, unless `overwritingExternalChanges`.
    /// A symlinked config (dotfiles setups) is written through to its
    /// target: an atomic write to the link itself would replace the link
    /// with a plain file and silently detach it from the dotfiles copy.
    func save(overwritingExternalChanges: Bool = false) throws {
        if !overwritingExternalChanges, try Self.readContents(at: path) != diskText {
            throw SaveError.changedOnDisk
        }
        let text = document.text
        try text.write(
            to: URL(fileURLWithPath: path).resolvingSymlinksInPath(),
            atomically: true,
            encoding: .utf8
        )
        diskText = text
        isDirty = false
    }

    /// Discard edits and re-read the file.
    func revert() throws {
        let contents = try Self.readContents(at: path)
        diskText = contents
        document = ConfigDocument(text: contents)
        isDirty = false
        refreshLayers()
    }

    /// Pick up edits made outside the editor (e.g. through "Edit in External
    /// Editor") when there is nothing unsaved to lose.
    ///
    /// Includes and the theme are re-read either way: they can change even
    /// while this file has unsaved edits.
    func reloadIfClean() {
        defer { refreshLayers() }
        guard !isDirty, let contents = try? Self.readContents(at: path), contents != diskText else {
            return
        }
        diskText = contents
        document = ConfigDocument(text: contents)
    }
}
