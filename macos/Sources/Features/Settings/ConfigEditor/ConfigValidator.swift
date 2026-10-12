import Foundation
import GhosttyKit

/// A problem libghostty reports for one line of the edited config.
struct ConfigIssue: Equatable {
    /// The key on the offending line, or `nil` when the line can't be tied
    /// to an entry.
    let key: String?
    /// The parser's message without the file/line prefix.
    let message: String
}

/// Checks config text with libghostty's own parser, so the editor reports
/// exactly what a reload would for the file itself. Only that text is
/// parsed: `config-file` includes are not followed and `theme` is not
/// resolved, so problems there still surface through the reload's error
/// window.
enum ConfigValidator {
    static func issues(in document: ConfigDocument) -> [ConfigIssue] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-config-check-\(UUID().uuidString)")
        do {
            try document.text.write(to: url, atomically: false, encoding: .utf8)
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let config = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, url.path)

        return (0..<ghostty_config_diagnostics_count(config)).map { index in
            let raw = String(cString: ghostty_config_get_diagnostic(config, index).message)
            return issue(from: raw, in: document)
        }
    }

    /// Diagnostics read `<path>:<line>:<key>: <message>`. The line number
    /// maps back to the document entry, which is more reliable than
    /// re-parsing the key out of the message.
    private static func issue(from raw: String, in document: ConfigDocument) -> ConfigIssue {
        guard
            let match = raw.firstMatch(of: #/:(\d+):\s*(.*)$/#),
            let lineNumber = Int(match.1),
            document.lines.indices.contains(lineNumber - 1),
            case .entry(let entry, _) = document.lines[lineNumber - 1]
        else {
            return ConfigIssue(key: nil, message: raw)
        }

        var message = String(match.2)
        if message.hasPrefix("\(entry.key): ") {
            message.removeFirst(entry.key.count + 2)
        }
        return ConfigIssue(key: entry.key, message: message)
    }
}
