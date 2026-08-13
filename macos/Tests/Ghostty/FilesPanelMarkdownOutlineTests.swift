import Testing
@testable import Ghostty

struct FilesPanelMarkdownOutlineTests {
    @Test func extractsHeadingsWithoutTreatingFencedContentAsOutline() {
        let outline = FilesPanelMarkdownOutline.parse("""
        Intro
        # First
        Body
        ```swift
        # Not a heading
        ```
        ## Second
        More
        """)

        #expect(outline.preamble == "Intro")
        #expect(outline.sections.map(\.title) == ["First", "Second"])
        #expect(outline.sections.map(\.level) == [1, 2])
        #expect(outline.sections[0].source.contains("# Not a heading"))
    }

    @Test func replaysLinkReferenceDefinitionsIntoEverySection() {
        let outline = FilesPanelMarkdownOutline.parse("""
        # First
        See [docs][ref].

        ## Second
        Also [docs][ref].

        [ref]: https://example.com
        """)

        #expect(outline.sections.count == 2)
        for section in outline.sections {
            #expect(section.source.contains("[ref]: https://example.com"))
        }
    }
}
