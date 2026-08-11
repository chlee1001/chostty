import Combine
import Foundation

@preconcurrency @MainActor
final class TerminalReaderStore: ObservableObject {
    enum Content: Sendable {
        case markdown(FilesPanelMarkdownDocument)
        case text(FilesPanelTextDocument)
        case image(FilesPanelImageDocument)
        case unsupported(path: String, kind: String, sizeBytes: Int64)

        var sourcePath: String {
            switch self {
            case .markdown(let document): document.sourcePath
            case .text(let document): document.sourcePath
            case .image(let document): document.sourcePath
            case .unsupported(let path, _, _): path
            }
        }

        var estimatedByteCost: Int {
            switch self {
            case .markdown(let document): document.estimatedByteCost
            case .text(let document): document.estimatedByteCost
            case .image(let document): document.estimatedByteCost
            case .unsupported: 0
            }
        }
    }

    enum LoadState: Sendable {
        case idle
        case loading(path: String)
        case content(Content)
        case failed(path: String, reason: String)
    }

    @Published private(set) var state: LoadState = .idle

    private let id = UUID()
    private let loader: any FilesPanelDocumentLoading
    private var activeTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private weak var budget: FilesPanelReaderMemoryBudget?

    init(loader: any FilesPanelDocumentLoading = FilesPanelDocumentLoader()) {
        self.loader = loader
    }

    deinit {
        activeTask?.cancel()
        budget?.release(id: id)
        budget?.unregister(id: id)
    }

    var current: Content? {
        guard case .content(let content) = state else { return nil }
        return content
    }
    var isOpen: Bool {
        if case .idle = state { return false }
        return true
    }

    func attach(budget: FilesPanelReaderMemoryBudget) {
        guard self.budget !== budget else { return }
        self.budget?.release(id: id)
        self.budget?.unregister(id: id)
        self.budget = budget
        budget.register(id: id) { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }

    func open(path: String) {
        switch state {
        case .loading(let loadingPath) where loadingPath == path:
            return
        case .content(let content) where content.sourcePath == path:
            return
        default:
            break
        }

        activeTask?.cancel()
        budget?.release(id: id)
        generation &+= 1
        let requestedGeneration = generation
        state = .loading(path: path)

        activeTask = Task { [weak self, loader] in
            let result = await loader.load(path: path)
            guard !Task.isCancelled, let self, self.generation == requestedGeneration else { return }
            switch result {
            case .success(let content):
                guard self.budget?.reserve(content.estimatedByteCost, for: self.id) ?? true else {
                    self.state = .failed(path: path, reason: "Reader memory limit exceeded")
                    self.activeTask = nil
                    return
                }
                self.state = .content(content)
            case .failure(let error):
                self.state = .failed(path: path, reason: String(describing: error))
            }
            self.activeTask = nil
        }
    }

    func reload() {
        let path: String?
        switch state {
        case .content(let content): path = content.sourcePath
        case .failed(let failedPath, _): path = failedPath
        case .idle, .loading: path = nil
        }
        guard let path else { return }
        close()
        open(path: path)
    }
    func close() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        budget?.release(id: id)
        state = .idle
    }
}
