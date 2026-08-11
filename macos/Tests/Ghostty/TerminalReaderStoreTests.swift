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
    }

    @Test func closeCancelsLoadingAndReturnsIdle() async throws {
        let loader = DelayedFilesPanelDocumentLoaderDouble()
        let store = TerminalReaderStore(loader: loader)
        store.open(path: "/tmp/a")
        store.close()
        try await Task.sleep(for: .milliseconds(150))
        guard case .idle = store.state else {
            Issue.record("reader did not remain idle")
            return
        }
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
