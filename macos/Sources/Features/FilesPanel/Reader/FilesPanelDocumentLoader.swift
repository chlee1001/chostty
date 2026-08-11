import Foundation
import ImageIO

protocol FilesPanelDocumentLoading: Sendable {
    func load(path: String) async -> Result<TerminalReaderStore.Content, FilesPanelDocumentLoader.LoadError>
}

actor FilesPanelDocumentLoader: FilesPanelDocumentLoading {
    enum LoadError: Error, Equatable, Sendable {
        case missing
        case permissionDenied
        case unreadable
        case invalidEncoding
        case invalidImage
    }

    func load(path: String) async -> Result<TerminalReaderStore.Content, LoadError> {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let size: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch CocoaError.fileReadNoSuchFile {
            return .failure(.missing)
        } catch CocoaError.fileReadNoPermission {
            return .failure(.permissionDenied)
        } catch {
            return .failure(.unreadable)
        }

        var kind = FilesPanelDocumentKind.classify(path: url.path, sizeBytes: size)
        if kind == .binary, let prefix = readPrefix(url: url) {
            kind = FilesPanelDocumentKind.classifyContent(prefix: prefix) ?? kind
        }

        if case .tooLarge(let limit) = kind {
            return .success(.unsupported(path: url.path, kind: "File exceeds \(limit) bytes", sizeBytes: size))
        }

        switch kind {
        case .markdown:
            guard let source = readText(url: url) else { return .failure(.invalidEncoding) }
            return .success(.markdown(.init(sourcePath: url.path, source: source)))
        case .text:
            guard let text = readText(url: url) else { return .failure(.invalidEncoding) }
            return .success(.text(.init(sourcePath: url.path, text: text)))
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return .failure(.invalidImage)
            }
            return .success(.image(.init(sourcePath: url.path, image: image)))
        case .pdf:
            return .success(.unsupported(path: url.path, kind: "PDF", sizeBytes: size))
        case .binary:
            return .success(.unsupported(path: url.path, kind: "Binary file", sizeBytes: size))
        case .tooLarge:
            preconditionFailure("handled above")
        }
    }

    private func readText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readPrefix(url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 8 * 1024)
    }
}
