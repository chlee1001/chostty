import Combine
import Foundation
import os

@preconcurrency @MainActor
final class TerminalReaderStore: ObservableObject {
    static let maximumDocuments = 20

    /// Reader diagnostics never include file contents — only paths the user
    /// explicitly opened, plus counts and failure reasons.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "kr.co.devch.chostty",
        category: String(describing: TerminalReaderStore.self)
    )

    enum Content: Sendable {
        case markdown(FilesPanelMarkdownDocument)
        case text(FilesPanelTextDocument)
        case structured(FilesPanelStructuredDocument)
        case html(FilesPanelTextDocument)
        case image(FilesPanelImageDocument)
        case unsupported(path: String, kind: String, sizeBytes: Int64)

        var sourcePath: String {
            switch self {
            case .markdown(let document): document.sourcePath
            case .text(let document): document.sourcePath
            case .structured(let document): document.sourcePath
            case .html(let document): document.sourcePath
            case .image(let document): document.sourcePath
            case .unsupported(let path, _, _): path
            }
        }

        var estimatedByteCost: Int {
            switch self {
            case .markdown(let document): document.estimatedByteCost
            case .text(let document): document.estimatedByteCost
            case .structured(let document): document.estimatedByteCost
            case .html(let document): document.estimatedByteCost
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

    struct Document: Identifiable, Sendable {
        let id: UUID
        let path: String
        var state: LoadState
        var isStale: Bool
        var viewState = ViewState()
    }

    struct ViewState: Sendable {
        enum ImageScaleMode: String, CaseIterable, Sendable {
            case fit = "Fit"
            case actual = "Actual Size"
            case custom = "Custom"
        }

        var searchQuery = ""
        var wrapsLines = false
        var showsStructure = true
        var showsHTMLPreview = true
        var imageScaleMode: ImageScaleMode = .fit
        var imageZoom = 1.0
        var expandedNodes: Set<String> = []
        var scrollLine = 0
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var documents: [Document] = []
    @Published private(set) var selectedDocumentID: UUID?
    @Published private(set) var isPresented = false
    @Published private(set) var notice: String?

    private let loader: any FilesPanelDocumentLoading
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UInt64] = [:]
    private weak var budget: FilesPanelReaderMemoryBudget?

    init(loader: any FilesPanelDocumentLoading = FilesPanelDocumentLoader()) {
        self.loader = loader
    }

    deinit {
        activeTasks.values.forEach { $0.cancel() }
        documents.forEach {
            budget?.release(id: $0.id)
            budget?.unregister(id: $0.id)
        }
    }

    var current: Content? {
        guard case .content(let content) = state else { return nil }
        return content
    }
    var isOpen: Bool {
        isPresented && !documents.isEmpty
    }

    func attach(budget: FilesPanelReaderMemoryBudget) {
        guard self.budget !== budget else { return }
        documents.forEach {
            self.budget?.release(id: $0.id)
            self.budget?.unregister(id: $0.id)
        }
        self.budget = budget
        documents.forEach { registerBudget(for: $0.id) }
    }

    func open(path: String) {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = documents.first(where: { $0.path == canonicalPath }) {
            select(id: existing.id)
            return
        }
        guard documents.count < Self.maximumDocuments else {
            notice = "Close a document before opening another (maximum \(Self.maximumDocuments))."
            return
        }

        notice = nil
        let id = UUID()
        documents.append(.init(
            id: id,
            path: canonicalPath,
            state: .loading(path: canonicalPath),
            isStale: false
        ))
        selectedDocumentID = id
        isPresented = true
        registerBudget(for: id)
        publishSelectedState()
        load(documentID: id)
    }

    func select(id: UUID) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        selectedDocumentID = id
        budget?.touch(id: id)
        isPresented = true
        notice = nil
        publishSelectedState()
        if document.isStale { load(documentID: id) }
    }

    func hide() {
        isPresented = false
    }

    func closeDocument(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        activeTasks.removeValue(forKey: id)?.cancel()
        generations.removeValue(forKey: id)
        budget?.release(id: id)
        budget?.unregister(id: id)
        documents.remove(at: index)

        if selectedDocumentID == id {
            selectedDocumentID = documents.indices.contains(index)
                ? documents[index].id
                : documents.last?.id
        }
        isPresented = !documents.isEmpty && isPresented
        publishSelectedState()
    }

    func closeSelectedDocument() {
        guard let selectedDocumentID else {
            Self.logger.debug("reader close requested with no selected document")
            return
        }
        closeDocument(id: selectedDocumentID)
    }

    func selectAdjacentDocument(offset: Int) {
        guard documents.count > 1,
              let selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == selectedDocumentID }) else { return }
        let nextIndex = (index + offset % documents.count + documents.count) % documents.count
        select(id: documents[nextIndex].id)
    }

    func viewState<Value>(
        for id: UUID,
        _ keyPath: KeyPath<ViewState, Value>,
        default defaultValue: Value
    ) -> Value {
        documents.first(where: { $0.id == id })?.viewState[keyPath: keyPath] ?? defaultValue
    }

    func updateViewState<Value>(
        for id: UUID,
        _ keyPath: WritableKeyPath<ViewState, Value>,
        to value: Value
    ) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].viewState[keyPath: keyPath] = value
    }

    func reload() {
        guard let selectedDocumentID else { return }
        load(documentID: selectedDocumentID)
    }

    func markStale(paths: Set<String>?) {
        let canonicalPaths = paths.map {
            Set($0.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        }
        var selectedChanged = false
        for index in documents.indices {
            let matches = canonicalPaths?.contains(documents[index].path) ?? true
            guard matches else { continue }
            documents[index].isStale = true
            selectedChanged = selectedChanged || documents[index].id == selectedDocumentID
        }
        guard isPresented, selectedChanged, let selectedDocumentID else { return }
        load(documentID: selectedDocumentID)
    }

    func markAllStale() {
        markStale(paths: nil)
    }

    func closeAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        generations.removeAll()
        documents.forEach {
            budget?.release(id: $0.id)
            budget?.unregister(id: $0.id)
        }
        documents.removeAll()
        selectedDocumentID = nil
        isPresented = false
        notice = nil
        state = .idle
    }

    private func registerBudget(for id: UUID) {
        budget?.register(id: id) { [weak self] in
            Task { @MainActor in self?.evictContent(documentID: id) }
        }
    }

    private func load(documentID: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let path = documents[index].path
        let retainedContent: Content?
        if case .content(let content) = documents[index].state {
            retainedContent = content
        } else {
            retainedContent = nil
        }
        activeTasks.removeValue(forKey: documentID)?.cancel()
        let generation = (generations[documentID] ?? 0) &+ 1
        generations[documentID] = generation
        if retainedContent == nil {
            budget?.release(id: documentID)
            documents[index].state = .loading(path: path)
        }
        documents[index].isStale = false
        publishSelectedState()

        activeTasks[documentID] = Task { [weak self, loader] in
            let result = await loader.load(path: path)
            guard !Task.isCancelled, let self,
                  self.generations[documentID] == generation,
                  let index = self.documents.firstIndex(where: { $0.id == documentID }) else { return }
            switch result {
            case .success(let content):
                if self.budget?.reserve(
                    content.estimatedByteCost,
                    for: documentID,
                    protecting: self.selectedDocumentID
                ) ?? true {
                    self.documents[index].state = .content(content)
                } else {
                    self.documents[index].state = .failed(path: path, reason: "Reader memory limit exceeded")
                }
            case .failure(let error):
                self.budget?.release(id: documentID)
                Self.logger.warning("reader load failed path=\(path, privacy: .public) reason=\(String(describing: error), privacy: .public)")
                self.documents[index].state = .failed(path: path, reason: error.message)
            }
            self.activeTasks.removeValue(forKey: documentID)
            self.publishSelectedState()
        }
    }

    private func evictContent(documentID: UUID) {
        guard documentID != selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        Self.logger.debug("reader evicted decoded content path=\(self.documents[index].path, privacy: .public)")
        documents[index].state = .idle
        documents[index].isStale = true
    }

    private func publishSelectedState() {
        guard isPresented,
              let selectedDocumentID,
              let selected = documents.first(where: { $0.id == selectedDocumentID }) else {
            state = .idle
            return
        }
        state = selected.state
    }
}
