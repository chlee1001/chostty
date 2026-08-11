import Foundation
import Testing
@testable import Ghostty

struct FilesPanelScannerTests {
    @Test func scansImmediateChildrenAndSortsDirectoriesFirst() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("z.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent(".hidden"))

        let nodes = try await FilesPanelScanner().children(of: root.path, showHidden: false)
        #expect(nodes.map(\.name) == ["folder", "z.txt"])
    }

    @Test func hiddenEntriesAppearOnlyWhenRequested() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("visible.txt"))

        let shown = try await FilesPanelScanner().children(of: root.path, showHidden: true)
        #expect(shown.map(\.name) == [".hidden", "visible.txt"])
    }

    @Test func listingStopsAtEntryCap() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<200 {
            try Data().write(to: root.appendingPathComponent("\(index).txt"))
        }

        let nodes = try await FilesPanelScanner().children(
            of: root.path,
            showHidden: false,
            maxEntries: 10
        )
        #expect(nodes.count == 10)
    }

    @Test func symbolicLinkIsListedWithoutBecomingAnExpandableDirectory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        let nodes = try await FilesPanelScanner().children(of: root.path, showHidden: false)
        #expect(nodes.map(\.kind) == [.symbolicLink])
        #expect(!(nodes.first?.isDirectory ?? true))
        #expect(nodes.first?.children == .loaded([]))
    }

    @Test func unreadableDirectoryReportsPermissionDenied() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        await #expect(throws: FilesPanelScanner.ScanError.unreadable(missing)) {
            try await FilesPanelScanner().children(of: missing, showHidden: false)
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
