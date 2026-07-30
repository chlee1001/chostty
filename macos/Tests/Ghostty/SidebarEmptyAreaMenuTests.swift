import Foundation
import Testing
@testable import Ghostty

/// Regression tests for right-clicking blank space below the last row in
/// the sidebar must open the workspace menu.
///
/// This shipped twice in a state that looked correct and did nothing. First as
/// `.background(Color.clear.contextMenu { ... })` on the ScrollView, where the
/// layer is painted behind the AppKit scroll view that hit-tests first and
/// swallows the right-click. Then as `.contextMenu` on the ScrollView itself,
/// which does not help either: blank space in a scroll view belongs to no
/// view, so there is nothing to hit-test and the click is dropped. Both
/// compiled, both read as correctly wired, and neither ever opened a menu.
///
/// Nothing in the build caught it. `SidebarFilterTests` asserts what the menu
/// items DO once invoked (`collapseAllExceptSelected` and friends), and those
/// tests were green the whole time, because the store calls were always fine —
/// the menu simply could not be reached. A test that only exercises the action
/// behind an affordance cannot tell you the affordance is dead.
///
/// Hosting the real view is not an option here: `NSHostingView` and an
/// on-screen `NSWindow` hang this XCTest host, the failure class
/// `WorkspaceDragDrop.swift` documents for `onDrop(of:delegate:)`. So this
/// suite pins the SHIPPED SOURCE for the three properties that together make
/// the blank region hit-testable, reusing the comment-stripping and
/// whitespace-normalizing transform from `VirtualTabBarScrollTests` so the
/// assertions match code and survive reformatting.
struct SidebarEmptyAreaMenuTests {
    private static let path = "Sources/Features/Sidebar/SidebarView.swift"

    private static func sourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../macos/Tests/Ghostty
            .deletingLastPathComponent() // .../macos/Tests
            .deletingLastPathComponent() // .../macos
            .appendingPathComponent(path)
    }

    private static let raw: String = {
        (try? String(contentsOf: sourceURL(), encoding: .utf8)) ?? ""
    }()

    /// Comments stripped, whitespace collapsed.
    private static let source: String = VirtualTabBarScrollTests.normalize(raw)

    @Test func sourceFileIsReadable() {
        // If this fails the path is wrong and every assertion below is
        // vacuously true — fail loudly rather than pass silently.
        #expect(!Self.source.isEmpty)
    }

    /// `normalize` strips `//` but not `/* */`, so a block comment would
    /// silently weaken every assertion here.
    @Test func sourceHasNoCommentFormsTheNormalizerCannotStrip() {
        #expect(!Self.raw.isEmpty)
        #expect(!Self.raw.contains("/*"))
    }

    // MARK: - The three properties that make blank space clickable

    /// The content must stretch to at least the viewport height. Without this
    /// the region below the last row is not part of any view and no amount of
    /// menu attachment reaches it.
    ///
    /// `minHeight`, never a fixed `height`: a list longer than the viewport
    /// must still scroll.
    @Test func contentStretchesToAtLeastTheViewportHeight() {
        #expect(Self.source.contains("minHeight: proxy.size.height"))
        #expect(!Self.source.contains("height: proxy.size.height,"))
    }

    /// A stack's hit area is otherwise only its children, which reproduces the
    /// same hole one level in.
    @Test func stretchedContentDeclaresAHitTestableShape() {
        #expect(Self.source.contains(".contentShape(Rectangle())"))
    }

    /// The menu must hang off the stretched content. Adjacency is the whole
    /// assertion: `.contentShape` and `.contextMenu` both appearing somewhere
    /// in a 900-line file proves nothing, since rows carry their own of each.
    @Test func menuIsAttachedToTheStretchedContentNotABackgroundLayer() {
        let anchor = ".contentShape(Rectangle()) .contextMenu { emptyAreaMenuItems }"
        #expect(Self.source.contains(anchor))
    }

    /// The original defect, pinned directly: the empty-area menu must not be
    /// reintroduced on a clear background layer, where it is painted behind
    /// the scroll view and never hit-tested.
    @Test func emptyAreaMenuIsNotOnAClearBackgroundLayer() {
        #expect(!Self.source.contains(".background(Color.clear .contentShape(Rectangle()) .contextMenu"))
    }

    /// `onDrop(of:delegate:)` deadlocks this test host. It must not appear in
    /// the sidebar at all — see `WorkspaceDragDrop.swift`.
    @Test func sidebarDoesNotUseTheDeadlockingDropAPI() {
        #expect(!Self.source.contains("onDrop(of:"))
    }
}
