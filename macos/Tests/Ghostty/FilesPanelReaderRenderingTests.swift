import Foundation
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct FilesPanelReaderRenderingTests {
    @Test func forkMarkdownExercisesRequiredRendererFeatures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forkURL = root.appendingPathComponent("FORK.md")
        let fork = try String(contentsOf: forkURL, encoding: .utf8)
        let rendererURL = root.appendingPathComponent(
            "macos/Sources/Features/FilesPanel/Reader/MarkdownUIRenderer.swift"
        )
        let renderer = try String(contentsOf: rendererURL, encoding: .utf8)

        #expect(fork.contains("| Chord | Action |"))
        #expect(fork.contains("|---"))
        #expect(renderer.contains("Markdown(document.source"))
        #expect(renderer.contains(".markdownImageProvider("))
        #expect(renderer.contains(".textSelection(.enabled)"))
    }

    @Test func rendererBoundaryAcceptsTablesTasksAndFencedCode() {
        let source = """
        | Name | Value |
        | --- | --- |
        | Files | Reader |

        - [x] table
        - [ ] image

        ```swift
        let reader = true
        ```
        """
        let document = FilesPanelMarkdownDocument(sourcePath: "/tmp/fixture.md", source: source)
        let spy = MarkdownRendererSpy()

        _ = spy.render(document)

        #expect(spy.renderedSource == source)
    }

    private final class MarkdownRendererSpy: MarkdownRenderer {
        private(set) var renderedSource: String?

        func render(_ document: FilesPanelMarkdownDocument) -> AnyView {
            renderedSource = document.source
            return AnyView(EmptyView())
        }
    }
}
