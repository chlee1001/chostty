import Foundation
import Testing
@testable import Ghostty

/// Reopening a closed tab recreates it from recorded metadata when the
/// original session can no longer be resurrected. That path applied the
/// recorded `pwd` unconditionally, while every other tab-creating path in this
/// fork drops a directory that no longer exists — `TerminalCommandRouter`
/// falls through for precisely this condition and
/// `WorkingDirectoryPrecedenceTests` pins it.
///
/// A record easily outlives its directory: a worktree removed, a build output
/// cleaned, an external volume ejected. Handing that dead path to a new
/// surface asks the shell to start somewhere that is gone.
@MainActor
struct ReopenWorkingDirectoryTests {
    private func record(pwd: String?) -> ClosedTabHistory.Record {
        ClosedTabHistory.Record(
            workspaceID: UUID(),
            workspaceName: "Workspace 1",
            index: 0,
            title: "Tab",
            titleOverride: nil,
            pwd: pwd,
            tabColor: .none)
    }

    @Test func anExistingDirectoryIsApplied() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chostty-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = BaseTerminalController.reopenConfig(for: record(pwd: dir.path))
        #expect(config.workingDirectory == dir.path)
    }

    /// The regression: the directory is gone by the time the tab is reopened.
    @Test func aDirectoryThatNoLongerExistsIsDropped() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chostty-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Recorded while it existed, removed before the reopen.
        let recorded = record(pwd: dir.path)
        try FileManager.default.removeItem(at: dir)

        let config = BaseTerminalController.reopenConfig(for: recorded)
        #expect(config.workingDirectory == nil)
    }

    /// A path that exists but is a file, not a directory, is equally unusable
    /// as a working directory — checking only for existence would let it
    /// through.
    @Test func aFileIsNotTreatedAsADirectory() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chostty-reopen-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let config = BaseTerminalController.reopenConfig(for: record(pwd: file.path))
        #expect(config.workingDirectory == nil)
    }

    @Test func noRecordedDirectoryLeavesTheConfigAlone() {
        let config = BaseTerminalController.reopenConfig(for: record(pwd: nil))
        #expect(config.workingDirectory == nil)
    }
}
