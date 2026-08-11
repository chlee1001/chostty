import Foundation
import Testing
@testable import Ghostty

@MainActor
struct FilesPanelTreeCacheEvictionTests {
    @Test func evictsLeastRecentlyExpandedDirectory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in ["a", "b"] {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data().write(to: url.appendingPathComponent("1.txt"))
            try Data().write(to: url.appendingPathComponent("2.txt"))
        }

        let model = FilesPanelTreeViewModel(maximumCachedNodes: 4)
        model.load(root: root.path, showHidden: false)
        try await waitUntil { model.state == .loaded }
        let firstPath = try #require(model.nodes.first(where: { $0.name == "a" })?.path)
        let firstExpansion = try #require(model.expand(path: firstPath))
        await firstExpansion.value
        #expect(model.cachedNodeCount == 4)
        let secondPath = try #require(model.nodes.first(where: { $0.name == "b" })?.path)
        let secondExpansion = try #require(model.expand(path: secondPath))
        await secondExpansion.value

        let first = try #require(model.nodes.first { $0.name == "a" })
        #expect(first.children == .unloaded)
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

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum TestError: Error { case timedOut }
}
