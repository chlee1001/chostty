import SwiftUI
import AppKit

/// The GUI configuration editor: curated category pages plus All Settings
/// (every key the binary knows), search across all of them, one row per
/// setting with inline documentation, and explicit Save & Apply. Comments
/// and lines the editor doesn't touch are preserved by ``ConfigDocument``.
struct ConfigEditorView: View {
    enum Pane: Hashable {
        case category(ConfigOption.Category)
        case all
    }

    @ObservedObject var model: ConfigEditorModel
    @State private var selection: Pane? = .category(.general)
    @State private var changedOnly = false
    @State private var saveError: String?
    @State private var showsConflict = false
    @State private var showsIssues = false

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 170, maxWidth: 240)
                detail
                    .frame(minWidth: 440)
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 520)
        .alert(
            "Couldn’t Save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert("Configuration Changed on Disk", isPresented: $showsConflict) {
            Button("Overwrite", role: .destructive) { saveAndApply(overwritingExternalChanges: true) }
            Button("Discard My Edits") { revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file was edited outside this window. Overwrite it with your edits, or discard them and load the file?")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search settings", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $selection) {
                Section("Common") {
                    ForEach(ConfigOption.Category.allCases) { category in
                        sidebarRow(
                            category.label,
                            systemImage: category.systemImage,
                            count: model.explicitCount(in: category)
                        )
                        .tag(Pane.category(category))
                    }
                }
                Section("Reference") {
                    sidebarRow("All Settings", systemImage: "list.bullet", count: model.explicitCount)
                        .tag(Pane.all)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func sidebarRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Detail

    /// Keys for other platforms, hidden from All Settings unless the file
    /// sets them (search still finds them).
    private static let foreignPrefixes = ["gtk-", "linux-", "x11-", "adw-"]

    private var allSettings: [ConfigOption] {
        model.allOptions.filter { option in
            if changedOnly { return model.isExplicit(option) }
            return model.isExplicit(option)
                || !Self.foreignPrefixes.contains { option.key.hasPrefix($0) }
        }
    }

    private var detail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if isSearching {
                    if model.searchResults.isEmpty {
                        Text("No settings match “\(model.searchText)”.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(model.searchResults) { option in
                        OptionRowView(model: model, option: option)
                    }
                } else {
                    switch selection ?? .category(.general) {
                    case .category(let category):
                        ForEach(model.options(in: category)) { option in
                            OptionRowView(model: model, option: option)
                        }
                    case .all:
                        allSettingsHeader
                        ForEach(allSettings) { option in
                            OptionRowView(model: model, option: option)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var allSettingsHeader: some View {
        HStack {
            Text("\(allSettings.count) settings")
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Changed only", isOn: $changedOnly)
                .toggleStyle(.checkbox)
        }
        .font(.callout)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.path)
            Spacer()
            if !model.issues.isEmpty {
                Button {
                    showsIssues.toggle()
                } label: {
                    Label(
                        model.issues.count == 1 ? "1 problem" : "\(model.issues.count) problems",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .popover(isPresented: $showsIssues, arrowEdge: .top) { issueList }
            }
            if model.isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Edit in External Editor") { openExternally() }
                .disabled(model.isDirty)
                .help("Save or revert first so the external editor sees the same state.")
            Button("Revert") { revert() }
                .disabled(!model.isDirty)
            // ⌘S rather than Return: Return confirms a text field, and
            // must not save the whole file behind the user's back.
            Button("Save & Apply") { saveAndApply() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)
        }
        .padding(10)
    }

    /// Every parser problem, including ones on lines the editor has no row
    /// for (unknown keys, typos).
    private var issueList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                Text(issue.key.map { "\($0): \(issue.message)" } ?? issue.message)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func saveAndApply(overwritingExternalChanges: Bool = false) {
        do {
            try model.save(overwritingExternalChanges: overwritingExternalChanges)
        } catch ConfigEditorModel.SaveError.changedOnDisk {
            showsConflict = true
            return
        } catch {
            saveError = error.localizedDescription
            return
        }
        (NSApplication.shared.delegate as? AppDelegate)?.reloadConfig(nil)
    }

    private func revert() {
        do {
            try model.revert()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func openExternally() {
        (NSApplication.shared.delegate as? AppDelegate)?.openConfigExternally(nil)
    }
}

/// One setting row: label, type-appropriate control, where the effective
/// value comes from, inline doc, and a Reset button whenever the file sets
/// the key explicitly.
private struct OptionRowView: View {
    @ObservedObject var model: ConfigEditorModel
    let option: ConfigOption

    @State private var showsThemes = false
    @State private var showsFullDoc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(option.label)
                    .frame(width: 180, alignment: .trailing)
                    .help(option.key)
                control
                    .frame(maxWidth: 340, alignment: .leading)
                if model.isExplicit(option) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .help("The file sets this key explicitly.")
                    Button("Reset") { model.reset(option) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Remove the key from this file.")
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(model.issues(for: option).enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 188)
            }
            if let note = sourceNote {
                Label(note.text, systemImage: note.isWarning ? "exclamationmark.triangle.fill" : "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .padding(.leading, 188)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Self.markdown(option.doc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fullDoc = model.referenceDocs[option.key], fullDoc != option.doc {
                    Button("More…") { showsFullDoc.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .popover(isPresented: $showsFullDoc, arrowEdge: .bottom) {
                            ScrollView {
                                Text(Self.markdown(fullDoc, preservingLines: true))
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                            .frame(width: 480, height: 360)
                        }
                }
            }
            .padding(.leading, 188)
        }
    }

    // MARK: Effective value

    /// Where the effective value comes from when it isn't simply this
    /// file's line or the built-in default.
    private var sourceNote: (text: String, isWarning: Bool)? {
        if case .list = option.kind {
            let counts = model.layers.externalValueCount(for: option.key)
            var parts: [String] = []
            if counts.theme > 0, let theme = model.layers.theme {
                parts.append("theme “\(theme.name)” adds \(counts.theme)")
            }
            if counts.includes > 0 {
                parts.append("included files add \(counts.includes)")
            }
            return parts.isEmpty ? nil : ("Besides these entries, " + parts.joined(separator: ", ") + ".", false)
        }
        if let include = model.overridingInclude(option),
           let value = include.document.value(forKey: option.key) {
            let name = (include.path as NSString).abbreviatingWithTildeInPath
            return ("Overridden by \(name), which sets “\(value)”.", true)
        }
        guard !model.isExplicit(option), let effective = model.effective(option) else { return nil }
        switch effective.source {
        case .file:
            return nil
        case .theme(let name):
            return ("From theme “\(name)”: \(effective.value)", false)
        case .include(let path):
            return ("From \((path as NSString).abbreviatingWithTildeInPath): \(effective.value)", false)
        }
    }

    /// Docs use backticks for literal values; a plain `Text(String)` would
    /// show them verbatim. Full upstream docs keep their line structure
    /// (lists, indented examples).
    private static func markdown(_ doc: String, preservingLines: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: preservingLines ? .inlineOnlyPreservingWhitespace : .full
        )
        return (try? AttributedString(markdown: doc, options: options)) ?? AttributedString(doc)
    }

    @ViewBuilder private var control: some View {
        switch option.kind {
        case .bool:
            Toggle(option.label, isOn: boolBinding)
                .toggleStyle(.switch)
                .labelsHidden()
        case .optionalBool:
            optionalBoolControl
        case .text:
            ValueField(model: model, option: option, width: 220)
        case .number:
            ValueField(model: model, option: option, width: 70)
        case .opacity:
            opacityControl
        case .choice(let cases):
            choiceControl(cases, optional: false)
        case .optionalChoice(let cases):
            choiceControl(cases, optional: true)
        case .color(let special):
            colorControl(special)
        case .list(let placeholder):
            StringListEditor(model: model, option: option, placeholder: placeholder)
        case .theme:
            HStack(spacing: 6) {
                ValueField(model: model, option: option, width: 200)
                Button("Browse…") { showsThemes = true }
            }
            .sheet(isPresented: $showsThemes) {
                ThemeGalleryView(model: model, option: option)
            }
        }
    }

    // MARK: Bindings

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { (model.displayedValue(option) ?? "false") == "true" },
            set: { model.setValue($0 ? "true" : "false", for: option) }
        )
    }

    /// Unset is a distinct third state for `?bool` keys (e.g. an unset
    /// `cursor-style-blink` still honors DEC mode 12), so it is not folded
    /// into On or Off.
    private var optionalBoolControl: some View {
        Picker(option.label, selection: Binding(
            get: { model.value(option) ?? "" },
            set: { value in
                if value.isEmpty {
                    model.reset(option)
                } else {
                    model.setValue(value, for: option)
                }
            }
        )) {
            Text("Default").tag("")
            Text("On").tag("true")
            Text("Off").tag("false")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func choiceControl(_ cases: [String], optional: Bool) -> some View {
        let unsetTag = "__unset__"
        return Picker(option.label, selection: Binding(
            get: {
                if let value = model.value(option) { return value }
                if optional { return unsetTag }
                return model.displayedValue(option) ?? cases.first ?? unsetTag
            },
            set: { value in
                if value == unsetTag {
                    model.reset(option)
                } else {
                    model.setValue(value, for: option)
                }
            }
        )) {
            if optional {
                Text("Default").tag(unsetTag)
            }
            // A stored value the schema doesn't list (e.g. a numeric
            // `background-blur` radius) stays selectable so the picker
            // never misrepresents the file.
            let current = model.value(option) ?? (optional ? nil : model.displayedValue(option))
            if let current, !cases.contains(current), current != unsetTag {
                Text(current).tag(current)
            }
            ForEach(cases, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var opacityControl: some View {
        let binding = Binding<Double>(
            get: {
                Double(model.displayedValue(option) ?? "1") ?? 1
            },
            set: { model.setValue(String(format: "%g", $0), for: option) }
        )
        return HStack(spacing: 8) {
            Slider(value: binding, in: 0...1, step: 0.01) { Text(option.label) }
                .labelsHidden()
                .frame(width: 160)
            Text("\(Int((binding.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func colorControl(_ special: [ConfigOption.Special]) -> some View {
        HStack(spacing: 6) {
            ValueField(model: model, option: option, width: 110)
            // No opacity: Ghostty colors are RGB only and reject `#rrggbbaa`.
            ColorPicker(
                option.label,
                selection: Binding(
                    get: { Self.parseColor(model.displayedValue(option)) ?? .gray },
                    set: { model.setValue(Self.hexString(from: $0), for: option) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .fixedSize()
            if !special.isEmpty {
                Menu {
                    ForEach(special, id: \.value) { entry in
                        Button(entry.label) { model.setValue(entry.value, for: option) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .fixedSize()
                .help("Special values accepted in place of a color.")
            }
        }
    }

    // MARK: Color conversion

    /// Swatch for a hex value. Named colors and the 9/12-digit forms show a
    /// neutral swatch.
    private static func parseColor(_ raw: String?) -> Color? {
        guard let raw, let rgb = ThemeCatalog.rgb(raw) else { return nil }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private static func hexString(from color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

/// A text field over one single-value key. It keeps its own text and
/// writes through on every change: binding straight to the stored value
/// would read back the trimmed form and eat a space the moment it is
/// typed (`Catppuccin Mocha`, `/bin/zsh -l`).
private struct ValueField: View {
    @ObservedObject var model: ConfigEditorModel
    let option: ConfigOption
    let width: CGFloat

    @State private var text = ""

    var body: some View {
        // The prompt shows what applies while the field is empty: a theme
        // or include value, else the default.
        TextField(option.label, text: $text, prompt: Text(model.displayedValue(option) ?? ""))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .onAppear { text = model.value(option) ?? "" }
            .onChange(of: text) { model.setValue($0, for: option) }
            .onChange(of: model.value(option)) { stored in
                // External change (Reset, color picker, revert): show it.
                if (stored ?? "") != ConfigDocument.normalizedValue(text) {
                    text = stored ?? ""
                }
            }
    }
}

/// Editor for repeatable keys (`keybind`, `font-family`, `palette`, …):
/// one value per row. Rows are drafted locally and only non-empty rows are
/// written through, so a freshly added empty row never reaches the file.
private struct StringListEditor: View {
    @ObservedObject var model: ConfigEditorModel
    let option: ConfigOption
    let placeholder: String

    /// Rows carry their own identity: index identity breaks when a middle
    /// row is removed (a stale binding can read past the end, and focus
    /// jumps to the wrong row).
    private struct Row: Identifiable {
        let id = UUID()
        var text: String
    }

    @State private var draft: [Row] = []

    /// The draft as the document stores it. It must normalize exactly like
    /// `ConfigDocument.setValues` (trimmed, empties dropped); otherwise a
    /// trailing space mid-typing reads as an external change and the
    /// re-sync below eats it.
    private var committed: [String] {
        draft
            .map { ConfigDocument.normalizedValue($0.text) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($draft) { $row in
                HStack(spacing: 4) {
                    TextField(placeholder, text: $row.text)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: row.text) { _ in commit() }
                    Button {
                        draft.removeAll { $0.id == row.id }
                        commit()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this entry.")
                }
            }
            Button {
                draft.append(Row(text: ""))
            } label: {
                Label("Add Entry", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .onAppear { draft = model.values(option).map { Row(text: $0) } }
        .onChange(of: model.values(option)) { newValue in
            // Re-sync only on external changes (e.g. Reset); an empty draft
            // row waiting for input must not be wiped out by write-through.
            if newValue != committed {
                draft = newValue.map { Row(text: $0) }
            }
        }
    }

    private func commit() {
        model.setValues(committed, for: option)
    }
}
