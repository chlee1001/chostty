import Foundation
import Testing
@testable import Ghostty

@Suite("ConfigDocument")
struct ConfigDocumentTests {
    @Test("round trip preserves comments, blanks and unknown keys")
    func roundTripPreservesSource() {
        let source = """
        # my config

        font-size = 14
          spaced-key = value # not a comment
        unknown-future-key = yes

        palette = 0=#ff0000
        """
        #expect(ConfigDocument(text: source + "\n").text == source + "\n")
        #expect(ConfigDocument(text: source).text == source)
        #expect(ConfigDocument(text: "").text == "")
    }

    @Test("parse mirrors ghostty line semantics")
    func parseSemantics() {
        let doc = ConfigDocument(text: "  font-size\t=\t14  \n# comment\nplain line\n=\n")
        #expect(doc.value(forKey: "font-size") == "14")
        #expect(doc.value(forKey: "plain line") == nil)
        #expect(doc.values(forKey: "=").isEmpty)
    }

    @Test("values split at the first equals sign")
    func firstEqualsSplit() {
        let doc = ConfigDocument(text: "keybind = ctrl+x=copy\n")
        #expect(doc.value(forKey: "keybind") == "ctrl+x=copy")
    }

    @Test("the last entry wins for single-value keys")
    func lastEntryWins() {
        let doc = ConfigDocument(text: "font-size = 12\nfont-size = 14\n")
        #expect(doc.value(forKey: "font-size") == "14")
    }

    @Test("setValue rewrites the last entry in place")
    func setValueInPlace() {
        var doc = ConfigDocument(text: "# lead\nfont-size = 12\n# tail\n")
        doc.setValue("16", forKey: "font-size")
        #expect(doc.text == "# lead\nfont-size = 16\n# tail\n")
    }

    @Test("setValue appends when the key is absent")
    func setValueAppends() {
        var doc = ConfigDocument(text: "# hi\n")
        doc.setValue("14", forKey: "font-size")
        #expect(doc.text == "# hi\nfont-size = 14\n")
    }

    @Test("setValue never lets newlines corrupt the file")
    func setValueSanitizes() {
        var doc = ConfigDocument(text: "")
        doc.setValue("14\nbogus-key = 1", forKey: "font-size")
        #expect(doc.text == "font-size = 14 bogus-key = 1\n")
        #expect(doc.value(forKey: "bogus-key") == nil)
    }

    @Test("removeValues drops every occurrence")
    func removeValues() {
        var doc = ConfigDocument(text: "keybind = a=b\nfont-size = 14\nkeybind = c=d\n")
        doc.removeValues(forKey: "keybind")
        #expect(doc.text == "font-size = 14\n")
    }

    @Test("repeatable keys keep file order and block position")
    func repeatableKeys() {
        var doc = ConfigDocument(text: "keybind = a=1\nfont-size = 14\nkeybind = a=2\n# keep\n")
        #expect(doc.values(forKey: "keybind") == ["a=1", "a=2"])
        doc.setValues(["b=1", "b=2", "b=3"], forKey: "keybind")
        #expect(doc.text == "keybind = b=1\nkeybind = b=2\nkeybind = b=3\nfont-size = 14\n# keep\n")
        doc.setValues([], forKey: "keybind")
        #expect(doc.text == "font-size = 14\n# keep\n")
    }

    @Test("setValues flattens newlines and drops empty rows")
    func setValuesFlattens() {
        var doc = ConfigDocument(text: "")
        doc.setValues(["a\nb", " c ", "", "  "], forKey: "keybind")
        #expect(doc.text == "keybind = a\nkeybind = b\nkeybind = c\n")
    }

    @Test("BOM and CRLF survive a round trip")
    func bomAndCRLF() {
        let bom = "\u{FEFF}font-size = 14\n"
        #expect(ConfigDocument(text: bom).text == bom)
        let crlf = "font-size = 14\r\nkeybind = a=1\r\n"
        #expect(ConfigDocument(text: crlf).text == crlf)
    }
}

@Suite("ConfigSchema")
struct ConfigSchemaTests {
    @Test("keys are unique config tokens")
    func keysAreUnique() {
        let keys = ConfigSchema.options.map(\.key)
        #expect(Set(keys).count == keys.count)
        for option in ConfigSchema.options {
            #expect(option.key == option.key.lowercased())
            #expect(!option.key.isEmpty)
            #expect(!option.key.contains(" "))
        }
    }

    @Test("every category has options")
    func everyCategoryCovered() {
        for category in ConfigOption.Category.allCases {
            #expect(!ConfigSchema.options.filter { $0.category == category }.isEmpty)
        }
    }

    /// Values the editor can write for `option` without the user typing.
    private func writableSamples(_ option: ConfigOption) -> [String] {
        switch option.kind {
        case .bool, .optionalBool: ["true", "false"]
        case .text, .number: option.defaultValue.map { [$0] } ?? []
        case .opacity: ["0.5"]
        case .choice(let cases), .optionalChoice(let cases): cases
        case .color(let special): ["#123456"] + special.map(\.value)
        case .list(let placeholder): [placeholder]
        case .theme: ["Builtin Dark", "light:Builtin Light,dark:Builtin Dark"]
        }
    }

    /// Anchors the hand-written catalog to `src/config/Config.zig`: a
    /// renamed key or enum case upstream fails here instead of producing a
    /// config error after Save & Apply.
    @Test("every key and offered value parses in libghostty")
    func schemaMatchesParser() {
        for option in ConfigSchema.options {
            for sample in writableSamples(option) {
                let doc = ConfigDocument(text: "\(option.key) = \(sample)\n")
                #expect(ConfigValidator.issues(in: doc).isEmpty, "\(option.key) = \(sample)")
            }
        }
    }
}

@Suite("ConfigValidator")
struct ConfigValidatorTests {
    @Test("problems map back to the key on their line")
    func issuesCarryKeys() throws {
        let doc = ConfigDocument(text: "# lead\nfont-size = 14\ncursor-style = triangle\nno-such-key = 1\n")
        let issues = ConfigValidator.issues(in: doc)
        #expect(issues.count == 2)
        let cursor = try #require(issues.first { $0.key == "cursor-style" })
        #expect(!cursor.message.hasPrefix("cursor-style:"))
        #expect(issues.contains { $0.key == "no-such-key" })
    }

    @Test("a valid file has no problems")
    func validFile() {
        #expect(ConfigValidator.issues(in: ConfigDocument(text: "font-size = 14\npalette = 0=#ff0000\n")).isEmpty)
    }

    @Test("the editor never writes alpha into a color")
    func colorsAreRGB() {
        // Ghostty colors reject #rrggbbaa; the picker must not offer it.
        #expect(!ConfigValidator.issues(in: ConfigDocument(text: "background = #11223344\n")).isEmpty)
    }
}

@Suite("ConfigEditorModel")
@MainActor
struct ConfigEditorModelTests {
    private func makeConfigFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-config-editor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config").path
        try "# lead\nfont-size = 12\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("save writes the document atomically and clears dirty")
    func saveWritesFile() throws {
        let path = try makeConfigFile()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let model = ConfigEditorModel(path: path, contents: "# lead\nfont-size = 12\n")
        #expect(!model.isDirty)
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        model.setValue("16", for: option)
        #expect(model.isDirty)
        try model.save()

        #expect(!model.isDirty)
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "# lead\nfont-size = 16\n")
    }

    @Test("revert discards edits and reloads the file")
    func revertDiscardsEdits() throws {
        let path = try makeConfigFile()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let model = ConfigEditorModel(path: path, contents: "# lead\nfont-size = 12\n")
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        model.setValue("16", for: option)
        #expect(model.isDirty)

        try model.revert()
        #expect(!model.isDirty)
        #expect(model.value(option) == "12")
    }

    @Test("clearing a value removes the key instead of writing it blank")
    func emptyValueRemovesKey() throws {
        let model = ConfigEditorModel(path: "/nonexistent", contents: "font-size = 12\n")
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        model.setValue("  ", for: option)
        #expect(model.document.text == "")
        #expect(model.isDirty)
    }

    @Test("invalid values surface as row issues")
    func liveValidation() throws {
        let model = ConfigEditorModel(path: "/nonexistent", contents: "")
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        model.setValue("big", for: option)
        #expect(model.issues(for: option).count == 1)
        model.setValue("14", for: option)
        #expect(model.issues(for: option).isEmpty)
    }

    @Test("save refuses to clobber edits made on disk")
    func saveDetectsExternalEdits() throws {
        let path = try makeConfigFile()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let model = ConfigEditorModel(path: path, contents: "# lead\nfont-size = 12\n")
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        model.setValue("16", for: option)
        try "font-size = 20\n".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(throws: ConfigEditorModel.SaveError.self) { try model.save() }
        #expect(model.isDirty)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "font-size = 20\n")

        try model.save(overwritingExternalChanges: true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# lead\nfont-size = 16\n")
    }

    @Test("a clean editor picks up external edits; a dirty one keeps its own")
    func reloadIfClean() throws {
        let path = try makeConfigFile()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let model = ConfigEditorModel(path: path, contents: "# lead\nfont-size = 12\n")
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        try "font-size = 20\n".write(toFile: path, atomically: true, encoding: .utf8)
        model.reloadIfClean()
        #expect(model.value(option) == "20")
        #expect(!model.isDirty)

        model.setValue("16", for: option)
        try "font-size = 30\n".write(toFile: path, atomically: true, encoding: .utf8)
        model.reloadIfClean()
        #expect(model.value(option) == "16")
    }

    @Test("save writes through a symlinked config")
    func saveFollowsSymlink() throws {
        let target = try makeConfigFile()
        let dir = URL(fileURLWithPath: target).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let model = ConfigEditorModel(path: link, contents: try ConfigEditorModel.readContents(at: link))
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        model.setValue("16", for: option)
        try model.save()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "# lead\nfont-size = 16\n")
    }

    @Test("reset marks the key non-explicit")
    func resetClearsExplicit() throws {
        let model = ConfigEditorModel(path: "/nonexistent", contents: "font-size = 12\n")
        let option = try #require(ConfigSchema.options.first { $0.key == "font-size" })
        #expect(model.isExplicit(option))
        model.reset(option)
        #expect(!model.isExplicit(option))
        #expect(model.isDirty)
    }
}
