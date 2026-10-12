import Foundation

/// A lossless, line-oriented model of a Ghostty config file.
///
/// Parsing mirrors the loader in `src/cli/args.zig` (`LineIterator`): each
/// line is trimmed of surrounding whitespace (space, tab, CR), blank lines
/// and lines whose first character is `#` are ignored by Ghostty, and
/// entries split at the first `=` with both sides trimmed. There are no
/// trailing comments — a `#` inside a value is literal (that is how
/// `palette = 0=#ff0000` works).
///
/// Everything the editor does not touch is written back byte for byte, so
/// comments, ordering, unknown keys and repeated (repeatable) keys survive
/// a round trip through the GUI.
struct ConfigDocument: Equatable {
    struct Entry: Equatable {
        /// The key exactly as Ghostty sees it: the trimmed text before the
        /// first `=`.
        var key: String
        /// The trimmed text after the first `=`.
        var value: String
    }

    enum Line: Equatable {
        /// Blank lines, comments, and lines Ghostty would reject. Verbatim.
        case raw(String)
        /// A `key = value` entry. `source` is the original line so untouched
        /// entries round-trip byte for byte; edited entries re-render as
        /// `key = value`.
        case entry(Entry, source: String)
    }

    private(set) var lines: [Line] = []

    /// Line ending style of the source file. Mixed files normalize to CRLF
    /// if any CRLF was present; Ghostty strips `\r` either way.
    private var usesCRLF = false
    private var hasBOM = false
    private var endsWithNewline = true

    private static let trimSet = CharacterSet(charactersIn: " \t\r")

    init(text: String) {
        var body = text
        if body.hasPrefix("\u{FEFF}") {
            hasBOM = true
            body.removeFirst()
        }
        guard !body.isEmpty else { return }

        usesCRLF = body.contains("\r\n")
        endsWithNewline = body.hasSuffix("\n") || body.hasSuffix("\r\n")

        var rawLines = body.components(separatedBy: "\n")
        if endsWithNewline { rawLines.removeLast() }
        lines = rawLines.map { raw in
            var line = String(raw)
            while line.hasSuffix("\r") { line.removeLast() }
            return Self.parseLine(line)
        }
    }

    private static func parseLine(_ line: String) -> Line {
        let trimmed = line.trimmingCharacters(in: trimSet)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return .raw(line) }
        guard let eq = trimmed.firstIndex(of: "=") else { return .raw(line) }
        let key = trimmed[..<eq].trimmingCharacters(in: trimSet)
        guard !key.isEmpty else { return .raw(line) }
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: trimSet)
        return .entry(Entry(key: String(key), value: String(value)), source: line)
    }

    var text: String {
        let newline = usesCRLF ? "\r\n" : "\n"
        var out = hasBOM ? "\u{FEFF}" : ""
        out += lines.map {
            switch $0 {
            case .raw(let raw): return raw
            case .entry(_, let source): return source
            }
        }.joined(separator: newline)
        if endsWithNewline && !lines.isEmpty { out += newline }
        return out
    }

    // MARK: Reading

    /// The value Ghostty ends up with for `key`: the last entry wins, since
    /// later lines override earlier ones during load.
    func value(forKey key: String) -> String? {
        values(forKey: key).last
    }

    /// All values for `key` in file order. Repeatable keys (`keybind`,
    /// `font-family`, `palette`, …) accumulate one entry per line.
    func values(forKey key: String) -> [String] {
        lines.compactMap {
            if case .entry(let entry, _) = $0, entry.key == key { return entry.value }
            return nil
        }
    }

    // MARK: Editing

    /// Set a single-value key. Rewrites the last entry in place; appends at
    /// the end of the file when the key is absent. Earlier duplicates are
    /// left alone (harmless: the last one wins).
    mutating func setValue(_ value: String, forKey key: String) {
        let sanitized = Self.normalizedValue(value)
        guard let index = lines.lastIndex(where: { Self.matches($0, key) }) else {
            appendEntry(key: key, value: sanitized)
            return
        }
        lines[index] = .entry(Entry(key: key, value: sanitized), source: "\(key) = \(sanitized)")
    }

    /// Set every value for a repeatable key. Existing entries are replaced
    /// as a block at the position of the first one so surrounding comments
    /// keep their place; an empty `values` removes the key entirely.
    ///
    /// Values are split on newlines and flattened: the config format is
    /// line-based and a value can never span lines.
    mutating func setValues(_ values: [String], forKey key: String) {
        let flattened = values
            .flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: Self.trimSet) }
            .filter { !$0.isEmpty }

        guard !flattened.isEmpty else {
            removeValues(forKey: key)
            return
        }

        let first = lines.firstIndex(where: { Self.matches($0, key) })
        lines.removeAll { Self.matches($0, key) }
        let newLines = flattened.map {
            Line.entry(Entry(key: key, value: $0), source: "\(key) = \($0)")
        }
        lines.insert(contentsOf: newLines, at: first ?? lines.endIndex)
    }

    /// Remove every entry for `key` (what the editor's Reset does).
    mutating func removeValues(forKey key: String) {
        lines.removeAll { Self.matches($0, key) }
    }

    /// A value as `setValue` stores it and Ghostty reads it back.
    ///
    /// Trust boundary: a pasted value can carry newlines, which would
    /// corrupt the line-based format. They collapse to spaces, then the
    /// value is trimmed the way the loader trims it.
    static func normalizedValue(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: trimSet)
    }

    private static func matches(_ line: Line, _ key: String) -> Bool {
        if case .entry(let entry, _) = line { return entry.key == key }
        return false
    }

    private mutating func appendEntry(key: String, value: String) {
        lines.append(.entry(Entry(key: key, value: value), source: "\(key) = \(value)"))
    }
}
