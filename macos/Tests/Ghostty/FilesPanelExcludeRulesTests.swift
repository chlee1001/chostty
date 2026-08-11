import Foundation
import Testing
@testable import Ghostty

struct FilesPanelExcludeRulesTests {
    private let rules = FilesPanelExcludeRules()

    @Test(arguments: [
        ".git", "node_modules", ".zig-cache", "zig-out", "zig-pkg", "build", ".build",
        "DerivedData", "Pods", ".venv", "venv", "__pycache__", ".next", ".svn", ".hg", ".gjc",
    ])
    func excludesDefaultDirectoryBasenames(_ name: String) {
        #expect(rules.excludesDirectory(named: name))
    }

    @Test func matchesBasenameRatherThanPath() {
        #expect(rules.excludesDirectory(named: URL(fileURLWithPath: "/tmp/deep/zig-pkg").lastPathComponent))
        #expect(rules.excludesDirectory(named: URL(fileURLWithPath: "/tmp/deep/.gjc").lastPathComponent))
    }

    @Test func keepsDocumentationHistoryVisible() {
        #expect(!rules.excludesDirectory(named: "history"))
        #expect(!rules.excludesDirectory(named: "docs/history"))
    }
}

struct FilesPanelRootResolverTests {
    private let resolver = FilesPanelRootResolver()

    @Test func usesFirstNonEmptyRootCandidate() {
        #expect(resolver.resolve(.init(
            focusedPanePWD: "  ",
            sessionPWD: "/tmp/session",
            workspacePWD: "/tmp/workspace",
            homeDirectory: "/tmp/home"
        )) == "/tmp/session")
    }

    @Test func fallsBackToHomeDirectory() {
        #expect(resolver.resolve(.init(
            focusedPanePWD: nil,
            sessionPWD: nil,
            workspacePWD: nil,
            homeDirectory: "/tmp/home"
        )) == "/tmp/home")
    }
}

struct FilesPanelPathFormattingTests {
    @Test func createsRootRelativePath() {
        #expect(FilesPanelPathFormatting.relativePath("/tmp/root/a/b.txt", to: "/tmp/root") == "a/b.txt")
        #expect(FilesPanelPathFormatting.relativePath("/tmp/other", to: "/tmp/root") == nil)
    }

    @Test func abbreviatesHomeDirectoryOnlyOnComponentBoundary() {
        #expect(FilesPanelPathFormatting.abbreviatedPath("/Users/me/a", homeDirectory: "/Users/me") == "~/a")
        #expect(FilesPanelPathFormatting.abbreviatedPath("/Users/mean", homeDirectory: "/Users/me") == "/Users/mean")
    }
}
