import Foundation

struct FilesPanelPathFormatting: Sendable {
    static func relativePath(_ path: String, to root: String) -> String? {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let fileComponents = fileURL.pathComponents
        let rootComponents = rootURL.pathComponents

        guard fileComponents.starts(with: rootComponents) else { return nil }
        let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    static func abbreviatedPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        guard standardized == home || standardized.hasPrefix(home + "/") else { return standardized }
        return "~" + standardized.dropFirst(home.count)
    }
}
