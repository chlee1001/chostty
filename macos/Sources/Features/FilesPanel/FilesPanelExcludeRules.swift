import Foundation

struct FilesPanelExcludeRules: Sendable {
    static let defaultDirectoryNames: Set<String> = [
        ".git",
        "node_modules",
        ".zig-cache",
        "zig-out",
        "zig-pkg",
        "build",
        ".build",
        "DerivedData",
        "Pods",
        ".venv",
        "venv",
        "__pycache__",
        ".next",
        ".svn",
        ".hg",
        ".gjc",
    ]

    let directoryNames: Set<String>

    init(directoryNames: Set<String> = defaultDirectoryNames) {
        self.directoryNames = directoryNames
    }

    func excludesDirectory(named name: String) -> Bool {
        directoryNames.contains(name)
    }
}
