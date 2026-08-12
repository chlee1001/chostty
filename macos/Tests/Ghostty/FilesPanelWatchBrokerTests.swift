import Foundation
import Testing
@testable import Ghostty

struct FilesPanelWatchBrokerTests {
    @Test func subscriptionsShareOneStreamAndReleaseOnce() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = FilesPanelWatchBroker()
        let first = try #require(broker.subscribe(root: root.path) { _ in })
        let second = try #require(broker.subscribe(root: root.path) { _ in })

        #expect(broker.activeStreamCount == 1)
        #expect(broker.subscriberCount(for: root.path) == 2)
        first.cancel()
        first.cancel()
        #expect(broker.activeStreamCount == 1)
        #expect(broker.subscriberCount(for: root.path) == 1)
        second.cancel()
        #expect(broker.activeStreamCount == 0)
    }

    @Test func deinitReleasesSubscription() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = FilesPanelWatchBroker()
        var subscription: FilesPanelWatchBroker.Subscription? = broker.subscribe(root: root.path) { _ in }
        try #require(subscription != nil)
        #expect(broker.subscriberCount(for: root.path) == 1)
        subscription = nil
        #expect(broker.subscriberCount(for: root.path) == 0)
        _ = subscription
    }

    @Test func identifiesBroadRoots() {
        #expect(FilesPanelWatchBroker.isBroadRoot("/"))
        #expect(FilesPanelWatchBroker.isBroadRoot("/tmp/home", homeDirectory: "/tmp/home"))
        #expect(!FilesPanelWatchBroker.isBroadRoot("/tmp/home/project", homeDirectory: "/tmp/home"))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
