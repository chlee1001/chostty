import Foundation

struct FilesPanelScanner: Sendable {
    /// Caps one directory listing. The panel expands lazily, so this bounds the
    /// node count of a single pathological directory, not a whole tree walk.
    static let maximumEntries = 8_000

    enum ScanError: LocalizedError, Equatable, Sendable {
        case permissionDenied(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied(let path): "No permission to read \(path)."
            case .unreadable(let path): "Couldn’t read \(path)."
            }
        }
    }

    let excludeRules: FilesPanelExcludeRules

    init(excludeRules: FilesPanelExcludeRules = .init()) {
        self.excludeRules = excludeRules
    }

    func children(
        of directory: String,
        showHidden: Bool,
        maxEntries: Int = maximumEntries
    ) async throws -> [FilesPanelNode] {
        try await runOffMain {
            try enumerateChildren(
                directory: URL(fileURLWithPath: directory).standardizedFileURL,
                showHidden: showHidden,
                maxEntries: maxEntries,
                excludeRules: excludeRules
            )
        }
    }

    private func runOffMain<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enumerateChildren(
        directory: URL,
        showHidden: Bool,
        maxEntries: Int,
        excludeRules: FilesPanelExcludeRules
    ) throws -> [FilesPanelNode] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch CocoaError.fileReadNoPermission {
            throw ScanError.permissionDenied(directory.path)
        } catch {
            throw ScanError.unreadable(directory.path)
        }

        return urls.compactMap { url in
            makeNode(url: url, showHidden: showHidden, excludeRules: excludeRules)
        }
        .sorted(by: nodeSort)
        .prefix(maxEntries)
        .map { $0 }
    }
    private func makeNode(
        url: URL,
        showHidden: Bool,
        excludeRules: FilesPanelExcludeRules
    ) -> FilesPanelNode? {
        let name = url.lastPathComponent
        guard name != ".DS_Store" else { return nil }
        guard showHidden || !name.hasPrefix(".") else { return nil }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return .init(path: url.path, name: name, kind: .symbolicLink)
        }
        if values?.isDirectory == true {
            guard !excludeRules.excludesDirectory(named: name) else { return nil }
            return .init(path: url.path, name: name, kind: .directory)
        }
        guard values?.isRegularFile == true else { return nil }
        return .init(path: url.path, name: name, kind: .file)
    }

    private func nodeSort(_ lhs: FilesPanelNode, _ rhs: FilesPanelNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
