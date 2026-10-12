import Foundation
import Testing
@testable import Ghostty

/// A scratch directory tree, removed on deinit.
private final class Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-config-layers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
}

@Suite("ThemeCatalog")
struct ThemeCatalogTests {
    @Test("theme values parse like Theme.parseCLI")
    func selectionParsing() throws {
        let single = try #require(ThemeCatalog.Selection("  Dracula "))
        #expect(!single.isPair)
        #expect(single.value == "Dracula")

        let pair = try #require(ThemeCatalog.Selection("light:Builtin Light,dark:Catppuccin Mocha"))
        #expect(pair.light == "Builtin Light")
        #expect(pair.dark == "Catppuccin Mocha")
        #expect(pair.name(prefersDark: true) == "Catppuccin Mocha")
        #expect(pair.value == "light:Builtin Light,dark:Catppuccin Mocha")

        #expect(ThemeCatalog.Selection("light:A") == nil)
        #expect(ThemeCatalog.Selection("light=A,dark=B") == nil)
        #expect(ThemeCatalog.Selection("") == nil)
    }

    @Test("a pair that names the same theme twice writes a bare name")
    func samePairCollapses() {
        #expect(ThemeCatalog.Selection(light: "X", dark: "X").value == "X")
    }

    @Test("user themes shadow bundled ones and carry preview colors")
    func discoveryOrder() throws {
        let scratch = try Scratch()
        try scratch.write("user/Shared", "background = #ffffff\nforeground = #000000\n")
        try scratch.write("bundle/Shared", "background = #000000\n")
        try scratch.write("bundle/Night", "background = #101010\npalette = 1=#cc0000\npalette = 2 = #00cc00\n")
        let directories: [(url: URL, isUser: Bool)] = [(scratch.url("user"), true), (scratch.url("bundle"), false)]

        let themes = ThemeCatalog.load(from: directories)
        #expect(themes.map(\.name) == ["Night", "Shared"])
        let shared = try #require(themes.first { $0.name == "Shared" })
        #expect(shared.isUser)
        #expect(!shared.isDark)
        let night = try #require(themes.first { $0.name == "Night" })
        #expect(night.isDark)
        #expect(night.palette == [1: "#cc0000", 2: "#00cc00"])

        #expect(ThemeCatalog.resolve("Shared", in: directories)?.path == scratch.url("user/Shared").path)
        #expect(ThemeCatalog.resolve("bundle/Night", in: directories) == nil)
    }

    @Test("the bundled themes all parse in libghostty")
    func bundledThemesParse() throws {
        let bundled = ThemeCatalog.directories().filter { !$0.isUser }
        let themes = ThemeCatalog.load(from: bundled)
        #expect(themes.count > 100)
        for theme in themes.prefix(25) {
            let text = try String(contentsOf: theme.url, encoding: .utf8)
            #expect(ConfigValidator.issues(in: ConfigDocument(text: text)).isEmpty, "\(theme.name)")
        }
    }
}

@Suite("ConfigLayers")
struct ConfigLayersTests {
    @Test("includes override the main file, which overrides the theme")
    func precedence() throws {
        let scratch = try Scratch()
        try scratch.write("themes/Night", "background = #101010\nforeground = #eeeeee\ncursor-color = #ff0000\n")
        try scratch.write("config/extra", "cursor-color = #00ff00\n")
        let mainPath = try scratch.write(
            "config/config",
            "theme = Night\nconfig-file = extra\nforeground = #ffffff\ncursor-color = #0000ff\n"
        )
        let main = ConfigDocument(text: try String(contentsOfFile: mainPath, encoding: .utf8))
        let layers = ConfigLayers(
            main: main,
            mainPath: mainPath,
            prefersDark: false,
            themeDirectories: [(scratch.url("themes"), true)]
        )

        #expect(layers.effective("background", main: main) == .init(value: "#101010", source: .theme(name: "Night")))
        #expect(layers.effective("foreground", main: main) == .init(value: "#ffffff", source: .file))
        let includePath = scratch.url("config/extra").path
        #expect(layers.effective("cursor-color", main: main) == .init(value: "#00ff00", source: .include(path: includePath)))
        #expect(layers.overridingInclude(for: "cursor-color")?.path == includePath)
        #expect(layers.effective("font-size", main: main) == nil)
    }

    @Test("a light/dark pair follows the appearance")
    func appearancePair() throws {
        let scratch = try Scratch()
        try scratch.write("themes/Day", "background = #fafafa\n")
        try scratch.write("themes/Night", "background = #101010\n")
        let main = ConfigDocument(text: "theme = light:Day,dark:Night\n")
        let directories: [(url: URL, isUser: Bool)] = [(scratch.url("themes"), true)]

        let dark = ConfigLayers(main: main, mainPath: "/x/config", prefersDark: true, themeDirectories: directories)
        let light = ConfigLayers(main: main, mainPath: "/x/config", prefersDark: false, themeDirectories: directories)
        #expect(dark.effective("background", main: main)?.value == "#101010")
        #expect(light.effective("background", main: main)?.value == "#fafafa")
    }

    @Test("nested includes resolve relative to their own file, and cycles stop")
    func nestedIncludes() throws {
        let scratch = try Scratch()
        try scratch.write("a/sub/b", "config-file = ../c\nfont-size = 15\n")
        try scratch.write("a/c", "config-file = sub/b\npalette = 0=#000000\n")
        let mainPath = try scratch.write("a/config", "config-file = ?sub/b\nconfig-file = missing\n")
        let main = ConfigDocument(text: try String(contentsOfFile: mainPath, encoding: .utf8))
        let layers = ConfigLayers(main: main, mainPath: mainPath, prefersDark: false, themeDirectories: [])

        #expect(layers.includes.map { ($0.path as NSString).lastPathComponent } == ["b", "c"])
        #expect(layers.effective("font-size", main: main)?.value == "15")
        #expect(layers.externalValueCount(for: "palette").includes == 1)
    }

    @Test("config-file paths expand like path.zig")
    func pathExpansion() {
        #expect(ConfigLayers.expandPath("?\"rel dir/x\"", relativeTo: "/base") == "/base/rel dir/x")
        #expect(ConfigLayers.expandPath("/abs/../abs/x", relativeTo: "/base") == "/abs/x")
        #expect(ConfigLayers.expandPath("~/x", relativeTo: "/base") == NSHomeDirectory() + "/x")
        #expect(ConfigLayers.expandPath("?", relativeTo: "/base") == nil)
    }

    @Test("the model re-resolves layers when the theme line changes")
    @MainActor
    func modelTracksTheme() throws {
        let scratch = try Scratch()
        try scratch.write("themes/Night", "background = #101010\n")
        let model = ConfigEditorModel(
            path: scratch.url("config").path,
            contents: "",
            themeDirectories: [(scratch.url("themes"), true)]
        )
        let theme = try #require(ConfigSchema.options.first { $0.key == "theme" })
        let background = try #require(ConfigSchema.options.first { $0.key == "background" })
        #expect(model.displayedValue(background) == "#282c34")

        model.setValue("Night", for: theme)
        #expect(model.displayedValue(background) == "#101010")
        #expect(model.effective(background)?.source == .theme(name: "Night"))
    }
}

@Suite("ConfigReference")
struct ConfigReferenceTests {
    private static let sample = """
    # The font families to use.
    #
    # Repeat it for fallbacks.
    font-family =
    font-family-bold =

    # Font size in points.
    font-size = 13

    # Palette colors.
    palette = 0=#1d1f21
    palette = 1=#cc6666

    # Click to move.
    cursor-click-to-move = true
    """

    @Test("parses keys, docs, defaults and grouped keys")
    func parse() throws {
        let entries = ConfigReference.parse(Self.sample)
        #expect(entries.map(\.key) == ["font-family", "font-family-bold", "font-size", "palette", "cursor-click-to-move"])
        let family = try #require(entries.first)
        #expect(family.doc == "The font families to use.\n\nRepeat it for fallbacks.")
        #expect(family.summary == "The font families to use.")
        #expect(entries[1].doc == family.doc)
        #expect(entries[2].defaults == ["13"])
        #expect(entries[3].defaults == ["0=#1d1f21", "1=#cc6666"])
    }

    @Test("generic rows pick list, switch or text from the field type")
    func genericKinds() {
        let entries = ConfigReference.parse(Self.sample)
        let kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, ConfigReference.option(for: $0).kind) })
        #expect(kinds["palette"] == .list(placeholder: "0=#1d1f21"))
        #expect(kinds["cursor-click-to-move"] == .bool)
        #expect(kinds["font-size"] == .text)
        #expect(ConfigReference.label(for: "macos-titlebar-style") == "macOS Titlebar Style")
    }

    @Test("the model merges the catalog behind curated rows")
    @MainActor
    func modelMerge() throws {
        let model = ConfigEditorModel(path: "/nonexistent", contents: "cursor-click-to-move = false\n")
        model.apply(reference: ConfigReference.parse(Self.sample))
        let size = try #require(model.allOptions.first { $0.key == "font-size" })
        #expect(size.category == .font)
        #expect(model.allOptions.contains { $0.key == "theme" })
        #expect(model.referenceDocs["font-size"] == "Font size in points.")

        model.searchText = "click"
        #expect(model.searchResults.first?.key == "cursor-click-to-move")
        #expect(model.explicitCount == 1)
    }

    @Test("this build's own +show-config covers every curated key")
    func liveCatalog() async throws {
        let entries = await ConfigReference.load()
        #expect(entries.count > 150)
        let keys = Set(entries.map(\.key))
        for option in ConfigSchema.options {
            #expect(keys.contains(option.key), "\(option.key)")
        }
        // No duplicates: grouped keys and repeated defaults fold into one entry.
        #expect(keys.count == entries.count)
    }
}

/// The hand-copied type sets in ``ConfigReference`` must match the field
/// types in `src/config/Config.zig`.
@Suite("ConfigReference source sync")
struct ConfigReferenceSourceTests {
    private func fieldTypes() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("src/config/Config.zig"),
            encoding: .utf8
        )
        var types: [String: String] = [:]
        for match in source.matches(of: #/(?m)^@?"?([a-z0-9-]+)"?: ([^ =,\n]+)/#) {
            let key = String(match.1)
            if types[key] == nil { types[key] = String(match.2) }
        }
        return types
    }

    @Test("bool and repeatable key sets match Config.zig")
    func typeSetsMatch() throws {
        let types = try fieldTypes()
        #expect(types.count > 150)
        let bools = Set(types.filter { $0.value == "bool" }.keys)
        #expect(bools == ConfigReference.boolKeys)

        let repeatableTypes: Set<String> = ["Keybinds", "Palette", "KeyRemapSet"]
        let repeatable = Set(types.filter {
            $0.value.hasPrefix("Repeatable") || repeatableTypes.contains($0.value)
        }.keys)
        #expect(repeatable == ConfigReference.repeatableKeys)
    }
}
