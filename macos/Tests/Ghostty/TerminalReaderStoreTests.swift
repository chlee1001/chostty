import Foundation
import Testing
@testable import Ghostty

actor DelayedFilesPanelDocumentLoaderDouble: FilesPanelDocumentLoading {
    private(set) var requests: [String] = []
    let delay: Duration

    init(delay: Duration = .milliseconds(100)) {
        self.delay = delay
    }

    func load(path: String) async -> Result<TerminalReaderStore.Content, FilesPanelDocumentLoader.LoadError> {
        requests.append(path)
        try? await Task.sleep(for: delay)
        return .success(.text(.init(sourcePath: path, text: path)))
    }
}

@MainActor
struct TerminalReaderStoreTests {
    @Test func newerOpenCancelsStalePublication() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble()
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        store.open(path: "/tmp/b")
        try await waitUntil {
            if case .content = store.state { return true }
            return false
        }

        guard case .content(let content) = store.state else {
            Issue.record("expected loaded content")
            return
        }
        #expect(content.sourcePath == "/tmp/b")
        #expect(store.documents.count == 2)
    }

    @Test func identicalInflightOpenIsNoOp() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble()
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        store.open(path: "/tmp/a")
        try await waitUntil {
            if case .content = store.state { return true }
            return false
        }
        #expect(await loader.requests == ["/tmp/a"])
        #expect(store.documents.count == 1)
    }

    @Test func closeCancelsLoadingAndReturnsIdle() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble()
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        store.closeAll()
        try await Task.sleep(for: .milliseconds(150))
        guard case .idle = store.state else {
            Issue.record("reader did not remain idle")
            return
        }
    }

    @Test func openingMoreThanLimitPreservesExistingDocuments() {
        let store = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        for index in 0..<TerminalReaderStore.maximumDocuments {
            store.open(path: "/tmp/\(index)")
        }

        let selectedBeforeOverflow = store.selectedDocumentID
        store.open(path: "/tmp/overflow")

        #expect(store.documents.count == TerminalReaderStore.maximumDocuments)
        #expect(store.selectedDocumentID == selectedBeforeOverflow)
        #expect(store.notice != nil)
    }

    @Test func hidePreservesTabsAndCloseDocumentRemovesOnlySelection() throws {
        let store = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        store.open(path: "/tmp/a")
        store.open(path: "/tmp/b")
        let selected = try #require(store.selectedDocumentID)

        store.hide()
        #expect(!store.isOpen)
        #expect(store.documents.count == 2)

        store.select(id: selected)
        store.closeDocument(id: selected)
        #expect(store.documents.count == 1)
        #expect(store.isOpen)
    }

    @Test func closeSelectedAdvancesToNeighborThenHidesAfterLastDocument() throws {
        let store = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        store.open(path: "/tmp/a")
        let first = try #require(store.selectedDocumentID)
        store.open(path: "/tmp/b")

        store.closeSelectedDocument()
        #expect(store.documents.count == 1)
        #expect(store.selectedDocumentID == first)
        #expect(store.isOpen)

        store.closeSelectedDocument()
        #expect(store.documents.isEmpty)
        #expect(!store.isOpen)
    }

    @Test func documentViewStateSurvivesSelectionChanges() throws {
        let store = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        store.open(path: "/tmp/a")
        let first = try #require(store.selectedDocumentID)
        store.updateViewState(for: first, \.searchQuery, to: "needle")
        store.updateViewState(for: first, \.wrapsLines, to: true)
        store.open(path: "/tmp/b")

        store.select(id: first)

        #expect(store.viewState(for: first, \.searchQuery, default: "") == "needle")
        #expect(store.viewState(for: first, \.wrapsLines, default: false))
    }

    @Test func staleBackgroundDocumentReloadsOnlyWhenSelected() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble(delay: .milliseconds(10))
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        store.open(path: "/tmp/b")
        try await waitUntil { await loader.requests.count == 2 }
        try await Task.sleep(for: .milliseconds(20))

        store.markAllStale()
        try await waitUntil { await loader.requests.count == 3 }
        let first = try #require(store.documents.first(where: { $0.path == "/tmp/a" }))
        #expect(first.isStale)

        store.select(id: first.id)
        try await waitUntil { await loader.requests.count == 4 }
        #expect(await loader.requests.last == "/tmp/a")
    }

    @Test func reloadRetainsVisibleContentUntilReplacementArrives() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble(delay: .milliseconds(20))
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        try await waitUntil {
            if case .content = store.state { return true }
            return false
        }

        store.reload()

        guard case .content(let content) = store.state else {
            Issue.record("reload replaced visible content with a loading placeholder")
            return
        }
        #expect(content.sourcePath == "/tmp/a")
        try await waitUntil { await loader.requests.count == 2 }
    }

    @Test func unrelatedFileEventDoesNotReloadSelectedDocument() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble(delay: .milliseconds(10))
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        try await waitUntil { await loader.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(20))

        store.markStale(paths: ["/tmp/unrelated"])
        try await Task.sleep(for: .milliseconds(30))

        #expect(await loader.requests.count == 1)
        #expect(!store.documents[0].isStale)
    }

    @Test func closingInflightDocumentCannotResurrectIt() async throws {
        let store = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        store.open(path: "/tmp/a")
        let id = try #require(store.selectedDocumentID)
        store.closeDocument(id: id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.documents.isEmpty)
        #expect(store.state.isIdle)
    }

    @Test func missingFileShowsHumanReadableReasonNotEnumCase() async throws {
        let store = TerminalReaderStore(loader: FilesPanelDocumentLoader())
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
            .path
        store.open(path: path)
        try await waitUntil {
            if case .failed = store.state { return true }
            return false
        }

        guard case .failed(_, let reason) = store.state else {
            Issue.record("expected a failed document")
            return
        }
        #expect(reason == FilesPanelDocumentLoader.LoadError.missing.message)
        #expect(!reason.contains("missing"))
        #expect(store.documents.count == 1)
    }

    @Test func virtualTabStoresRemainIsolated() {
        let first = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        let second = TerminalReaderStore(loader: DelayedFilesPanelDocumentLoaderDouble())
        first.open(path: "/tmp/a")
        second.open(path: "/tmp/b")

        #expect(first.documents.map(\.path) == ["/tmp/a"])
        #expect(second.documents.map(\.path) == ["/tmp/b"])
        first.hide()
        #expect(!first.isOpen)
        #expect(second.isOpen)
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw TestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum TestError: Error { case timedOut }
}

private extension TerminalReaderStore.LoadState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}
