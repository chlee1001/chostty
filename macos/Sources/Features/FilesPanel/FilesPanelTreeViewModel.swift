import Combine
import Foundation

@MainActor
final class FilesPanelTreeViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var nodes: [FilesPanelNode] = []
    @Published private(set) var state: State = .idle
    @Published var filter = ""

    private let scanner: FilesPanelScanner
    private let maximumCachedNodes: Int
    private var root: String?
    private var showHidden = false
    private var loadTask: Task<Void, Never>?
    private var expandedPaths: [String] = []

    init(scanner: FilesPanelScanner = .init(), maximumCachedNodes: Int = 8_000) {
        self.scanner = scanner
        self.maximumCachedNodes = maximumCachedNodes
    }

    deinit { loadTask?.cancel() }

    var visibleNodes: [FilesPanelNode] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return filterNodes(nodes, query: query)
    }
    var cachedNodeCount: Int { countNodes(nodes) }

    func load(root: String, showHidden: Bool) {
        loadTask?.cancel()
        self.root = root
        self.showHidden = showHidden
        state = .loading
        loadTask = Task { [weak self, scanner] in
            do {
                let children = try await scanner.children(of: root, showHidden: showHidden)
                guard !Task.isCancelled else { return }
                self?.nodes = children
                self?.state = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.nodes = []
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func reload() {
        guard let root else { return }
        load(root: root, showHidden: showHidden)
    }

    @discardableResult
    func expand(path: String) -> Task<Void, Never>? {
        guard let node = findNode(path: path, in: nodes), node.isDirectory else { return nil }
        setChildren(.loading, at: path)
        let task = Task { [weak self, scanner] in
            do {
                let children = try await scanner.children(of: path, showHidden: self?.showHidden ?? false)
                guard !Task.isCancelled, let self else { return }
                self.setChildren(.loaded(children), at: path)
                self.touchExpanded(path)
                self.evictIfNeeded(excluding: path)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.setChildren(.failed(error.localizedDescription), at: path)
            }
        }
        loadTask = task
        return task
    }

    func collapse(path: String) {
        expandedPaths.removeAll { $0 == path }
    }

    private func touchExpanded(_ path: String) {
        expandedPaths.removeAll { $0 == path }
        expandedPaths.append(path)
    }

    private func evictIfNeeded(excluding protectedPath: String) {
        while countNodes(nodes) > maximumCachedNodes,
              let victim = expandedPaths.first(where: { $0 != protectedPath }) {
            setChildren(.unloaded, at: victim)
            expandedPaths.removeAll { $0 == victim }
        }
    }

    private func countNodes(_ nodes: [FilesPanelNode]) -> Int {
        nodes.reduce(0) { count, node in
            guard case .loaded(let children) = node.children else { return count + 1 }
            return count + 1 + countNodes(children)
        }
    }

    private func findNode(path: String, in nodes: [FilesPanelNode]) -> FilesPanelNode? {
        for node in nodes {
            if node.path == path { return node }
            if case .loaded(let children) = node.children,
               let result = findNode(path: path, in: children) {
                return result
            }
        }
        return nil
    }

    private func setChildren(_ children: FilesPanelNode.Children, at path: String) {
        func replacing(_ source: [FilesPanelNode]) -> [FilesPanelNode] {
            source.map { node in
                var node = node
                if node.path == path {
                    node.children = children
                } else if case .loaded(let descendants) = node.children {
                    node.children = .loaded(replacing(descendants))
                }
                return node
            }
        }
        nodes = replacing(nodes)
    }

    private func filterNodes(_ source: [FilesPanelNode], query: String) -> [FilesPanelNode] {
        source.compactMap { node in
            var node = node
            if case .loaded(let children) = node.children {
                node.children = .loaded(filterNodes(children, query: query))
            }
            let childMatches: Bool
            if case .loaded(let children) = node.children {
                childMatches = !children.isEmpty
            } else {
                childMatches = false
            }
            return node.name.localizedCaseInsensitiveContains(query) || childMatches ? node : nil
        }
    }
}
