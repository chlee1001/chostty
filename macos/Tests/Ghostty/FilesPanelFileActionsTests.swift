import AppKit
import Testing
@testable import Ghostty

@MainActor
struct FilesPanelFileActionsTests {
    @Test func copiesAbsolutePath() {
        FilesPanelFileActions.copyAbsolutePath("/tmp/a file.md")
        #expect(NSPasteboard.general.string(forType: .string) == "/tmp/a file.md")
    }

    @Test func copiesRelativePathWhenFileIsUnderRoot() {
        FilesPanelFileActions.copyRelativePath("/tmp/project/docs/read me.md", root: "/tmp/project")
        #expect(NSPasteboard.general.string(forType: .string) == "docs/read me.md")
    }

    @Test func relativeCopyFallsBackToAbsolutePathOutsideRoot() {
        FilesPanelFileActions.copyRelativePath("/tmp/other/readme.md", root: "/tmp/project")
        #expect(NSPasteboard.general.string(forType: .string) == "/tmp/other/readme.md")
    }
}
