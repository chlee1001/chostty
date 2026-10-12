import SwiftUI

/// The theme picker: every user and bundled theme as a preview card, with
/// search, a dark/light filter, and an optional separate theme per
/// appearance (`light:…,dark:…`).
struct ThemeGalleryView: View {
    @ObservedObject var model: ConfigEditorModel
    let option: ConfigOption

    @Environment(\.dismiss) private var dismiss

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case dark = "Dark"
        case light = "Light"
        var id: Self { self }
    }

    private enum Side: String, CaseIterable, Identifiable {
        case light = "Light Mode"
        case dark = "Dark Mode"
        var id: Self { self }
    }

    @State private var themes: [ThemeInfo] = []
    @State private var isLoading = true
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var perAppearance = false
    @State private var side: Side = .dark
    @State private var light: String?
    @State private var dark: String?

    private var filtered: [ThemeInfo] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return themes.filter { theme in
            switch filter {
            case .all: break
            case .dark: if !theme.isDark { return false }
            case .light: if theme.isDark { return false }
            }
            return needle.isEmpty || theme.name.lowercased().contains(needle)
        }
    }

    /// The `theme` value Apply writes, or `nil` until something is chosen.
    private var selection: ThemeCatalog.Selection? {
        if perAppearance {
            guard let light, let dark else { return nil }
            return ThemeCatalog.Selection(light: light, dark: dark)
        }
        let name = side == .dark ? dark : light
        return name.map { ThemeCatalog.Selection(light: $0, dark: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540, idealHeight: 640)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search \(themes.count) themes", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Toggle("Different theme per appearance", isOn: $perAppearance)
                .onChange(of: perAppearance) { enabled in
                    // Splitting starts both sides from the single theme.
                    if enabled {
                        let current = side == .dark ? dark : light
                        light = light ?? current
                        dark = dark ?? current
                    }
                }
            if perAppearance {
                Picker("Choosing for", selection: $side) {
                    ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(12)
    }

    // MARK: Grid

    @ViewBuilder private var grid: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text(themes.isEmpty ? "No themes found." : "No themes match.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(filtered) { theme in
                        // Double-click first so it is not swallowed by the
                        // single-click recognizer.
                        ThemeCard(theme: theme, badges: badges(for: theme))
                            .onTapGesture(count: 2) {
                                choose(theme)
                                apply()
                            }
                            .onTapGesture { choose(theme) }
                    }
                }
                .padding(12)
            }
        }
    }

    private func badges(for theme: ThemeInfo) -> [String] {
        if perAppearance {
            return [theme.name == light ? "Light" : nil, theme.name == dark ? "Dark" : nil].compactMap { $0 }
        }
        return (side == .dark ? dark : light) == theme.name ? ["Selected"] : []
    }

    private func choose(_ theme: ThemeInfo) {
        if perAppearance {
            if side == .dark { dark = theme.name } else { light = theme.name }
        } else {
            light = theme.name
            dark = theme.name
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(selection.map { "theme = \($0.value)" } ?? "Click a theme to choose it.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Use Theme") { apply() }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
        }
        .padding(12)
    }

    private func apply() {
        guard let selection else { return }
        model.setValue(selection.value, for: option)
        dismiss()
    }

    // MARK: Loading

    private func load() async {
        if let current = model.value(option).flatMap(ThemeCatalog.Selection.init) {
            perAppearance = current.isPair
            light = current.light
            dark = current.dark
        }
        side = model.prefersDark ? .dark : .light
        let directories = model.themeDirectories
        themes = await Task.detached(priority: .userInitiated) {
            ThemeCatalog.load(from: directories)
        }.value
        isLoading = false
    }
}

/// A theme as a miniature terminal: its background, foreground, a short
/// colored listing, and the eight base palette colors.
private struct ThemeCard: View {
    let theme: ThemeInfo
    let badges: [String]

    private func color(_ raw: String?, fallback: Color) -> Color {
        guard let raw, let rgb = ThemeCatalog.rgb(raw) else { return fallback }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private func paletteColor(_ index: Int) -> Color {
        color(theme.palette[index], fallback: foreground)
    }

    private var background: Color { color(theme.background, fallback: Color(white: 0.16)) }
    private var foreground: Color { color(theme.foreground, fallback: .white) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
            HStack(spacing: 4) {
                Text(theme.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(theme.name)
                Spacer(minLength: 0)
                if theme.isUser {
                    Text("User").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(badges.isEmpty ? Color.clear : Color.accentColor, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(badges.isEmpty ? [.isButton] : [.isButton, .isSelected])
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("~/src ").foregroundStyle(paletteColor(4))
                Text("$ ").foregroundStyle(paletteColor(2))
                Text("ls").foregroundStyle(foreground)
                Rectangle()
                    .fill(color(theme.cursor, fallback: foreground))
                    .frame(width: 6, height: 11)
            }
            HStack(spacing: 0) {
                Text("main.zig ").foregroundStyle(foreground)
                Text("build/ ").foregroundStyle(paletteColor(4))
                Text("run.sh").foregroundStyle(paletteColor(2))
            }
            Text("error: exit 1").foregroundStyle(paletteColor(1))
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { index in
                    paletteColor(index).frame(height: 8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .frame(height: 86)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }
}
