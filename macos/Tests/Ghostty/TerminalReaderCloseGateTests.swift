import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalReaderCloseGateTests {
    @Test func liveSurfaceCloseInterceptsOnlyWhenReaderIsOpen() {
        #expect(BaseTerminalController.shouldInterceptSurfaceClose(
            processExited: false,
            readerOpen: true
        ))
        #expect(!BaseTerminalController.shouldInterceptSurfaceClose(
            processExited: false,
            readerOpen: false
        ))
        #expect(!BaseTerminalController.shouldInterceptSurfaceClose(
            processExited: true,
            readerOpen: true
        ))
    }

    @Test func windowCloseMakesEveryReaderIdleAndReleasesBudget() async throws {
        let first = TerminalSessionState(id: UUID(), surfaceTree: .init())
        let second = TerminalSessionState(id: UUID(), surfaceTree: .init())
        let budget = FilesPanelReaderMemoryBudget(maximumBytes: 1_024)
        first.readerStore.attach(budget: budget)
        second.readerStore.attach(budget: budget)

        let firstURL = try temporaryTextFile(contents: "first")
        let secondURL = try temporaryTextFile(contents: "second")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        first.readerStore.open(path: firstURL.path)
        second.readerStore.open(path: secondURL.path)
        try await waitUntil { budget.currentUsedBytes > 0 }

        TerminalController.closeReadersBeforeWindowUndo([first, second])

        guard case .idle = first.readerStore.state else {
            Issue.record("first reader stayed open")
            return
        }
        guard case .idle = second.readerStore.state else {
            Issue.record("second reader stayed open")
            return
        }
        #expect(budget.currentUsedBytes == 0)
    }

    @Test func teardownPrecedesWindowUndoCapture() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Terminal/TerminalController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let function = try #require(source.range(of: "func closeWindowImmediately()"))
        let tail = source[function.lowerBound...]
        let cancel = try #require(tail.range(of: "cancelPendingInitialPresentation()"))
        let close = try #require(tail.range(of: "Self.closeReadersBeforeWindowUndo(workspaceStore.allSessions)"))
        let undo = try #require(tail.range(of: "registerUndoForCloseWindow()"))

        #expect(cancel.lowerBound < close.lowerBound)
        #expect(close.lowerBound < undo.lowerBound)
    }

    private func temporaryTextFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum TestError: Error { case timedOut }
}
