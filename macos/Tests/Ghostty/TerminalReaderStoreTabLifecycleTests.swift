import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalReaderStoreTabLifecycleTests {
    @Test func sessionTeardownClosesReaderAndReleasesBudget() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("reader".utf8).write(to: url)

        let session = TerminalSessionState(id: UUID(), surfaceTree: .init())
        let budget = FilesPanelReaderMemoryBudget(maximumBytes: 1024)
        session.readerStore.attach(budget: budget)
        session.readerStore.open(path: url.path)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while budget.currentUsedBytes == 0 {
            guard clock.now < deadline else { throw TestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(budget.currentUsedBytes > 0)

        session.tearDown()
        guard case .idle = session.readerStore.state else {
            Issue.record("reader stayed open after session teardown")
            return
        }
        #expect(budget.currentUsedBytes == 0)
    }

    private enum TestError: Error { case timedOut }
}
