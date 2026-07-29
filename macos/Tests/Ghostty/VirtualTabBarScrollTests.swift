import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Tests for F9 (tab bar scroll + minimum width).
///
/// Actually hosting `VirtualTabBar` (`NSHostingView`, an on-screen
/// `NSWindow`, even `ImageRenderer`) reliably hung or crashed the XCTest
/// host in this sandbox — "The test runner hung before establishing
/// connection.", the exact failure class `WorkspaceDragDrop.swift` already
/// documents for `onDrop(of:delegate:)`. Real SwiftUI layout hosting is not
/// safe to exercise from this test target.
///
/// So instead of asserting the pure `tabItemWidth` function against itself
/// (the tautology trap the plan calls out), these tests pin the SHIPPED
/// SOURCE: they read `VirtualTabBar.swift` and assert the item-body frame
/// site literally calls `tabItemWidth(availableWidth:tabCount:)` with the
/// real `GeometryReader` proxy — not a decoupled call nothing in production
/// reaches — while the container/label `maxWidth: .infinity` frames and the
/// `count > 1` single-tab guard stay untouched.
struct VirtualTabBarScrollTests {
    /// The shipped source with COMMENTS STRIPPED and whitespace normalized.
    ///
    /// Both transforms are load-bearing, and each fixes a real defect a
    /// red-team pass demonstrated on the naive version:
    ///
    /// - Stripping comments: a doc comment on `VirtualTabBarItem` mentioning
    ///   ``.frame(maxWidth: .infinity)`` satisfied the assertion that guards
    ///   the CONTAINER's frame. Breaking the real container frame left the
    ///   test green — the assertion was theatre, matching prose rather than
    ///   code.
    /// - Normalizing whitespace: a purely cosmetic re-wrap of
    ///   ``.frame(width: itemWidth)`` across several lines failed the suite
    ///   with zero behavior change, so any formatter pass would have.
    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../macos/Tests/Ghostty
            .deletingLastPathComponent() // .../macos/Tests
            .deletingLastPathComponent() // .../macos
            .appendingPathComponent("Sources/Features/Sidebar/VirtualTabBar.swift")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return normalize(raw)
    }()

    /// Drops `//` comment lines and collapses runs of whitespace, so these
    /// assertions match CODE and are insensitive to formatting.
    static func normalize(_ raw: String) -> String {
        let codeOnly = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                // Truncate at the FIRST `//`, not just drop whole-comment
                // lines: a trailing `.padding(4) // .frame(maxWidth: .infinity)`
                // would otherwise re-open the exact hole that made the
                // container assertion theatre. Safe here because
                // VirtualTabBar.swift has no string literal containing `//`,
                // which `sourceHasNoCommentFormsTheNormalizerCannotStrip`
                // pins.
                guard let r = line.range(of: "//") else { return line }
                return line[line.startIndex..<r.lowerBound]
            }
            .joined(separator: "\n")
        return codeOnly
            // Runs of whitespace -> one space.
            .replacingOccurrences(
                of: "[ \t\n]+",
                with: " ",
                options: .regularExpression)
            // ...then drop the spaces a re-wrap leaves just inside brackets,
            // so `.frame(\n  width: x\n)` normalizes to `.frame(width: x)`.
            .replacingOccurrences(
                of: "([(\\[]) ",
                with: "$1",
                options: .regularExpression)
            .replacingOccurrences(
                of: " ([)\\]])",
                with: "$1",
                options: .regularExpression)
    }

    /// Block comments are NOT stripped by `normalize`, so one appearing in
    /// `VirtualTabBar.swift` would silently weaken every assertion below.
    /// Fail loudly rather than degrade quietly.
    @Test func sourceHasNoCommentFormsTheNormalizerCannotStrip() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Sidebar/VirtualTabBar.swift")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!raw.isEmpty)
        #expect(!raw.contains("/*"))
    }

    @Test func sourceFileIsReadable() {
        // If this fails, the path resolution above is wrong and every other
        // test in this suite is vacuously true — fail loudly instead.
        #expect(!Self.source.isEmpty)
    }

    // MARK: - Pure function

    @Test func tabItemWidthClampsPerAcceptance() {
        #expect(VirtualTabBar.tabItemWidth(availableWidth: 400, tabCount: 20).points == 120)
        #expect(VirtualTabBar.tabItemWidth(availableWidth: 4000, tabCount: 2).points == 240)
        // Must not divide by zero.
        #expect(VirtualTabBar.tabItemWidth(availableWidth: 0, tabCount: 0).points == 120)
    }

    // MARK: - Shipped call-site pinning

    /// The item body's frame MUST be the fixed `itemWidth.points`, not
    /// `maxWidth: .infinity` — that's the one frame site F9 changes.
    @Test func itemBodyFrameUsesFixedItemWidthNotMaxWidthInfinity() {
        #expect(Self.source.contains(".frame(width: itemWidth.points)"))
    }

    /// `itemWidth` MUST be computed from the real `GeometryReader`'s
    /// reported size via the pure function — not a literal constant and not
    /// a call nothing in the shipped tree reaches.
    ///
    /// `GeometryReader { proxy in` MUST occur EXACTLY ONCE: a second
    /// occurrence would mean the dead `VirtualTabItemWidthPreferenceKey`
    /// seam (or some other decoupled reader) is back, and bare `.contains`
    /// can't tell "the real one" from "a second one" — deleting the real
    /// `GeometryReader` while leaving a decoy previously kept this suite
    /// green.
    @Test func itemWidthIsComputedFromGeometryReaderViaThePureFunction() {
        let occurrences = Self.source.components(separatedBy: "GeometryReader { proxy in").count - 1
        #expect(occurrences == 1)
        // Anchored as one contiguous chain (not three independent
        // `.contains` calls) so the specific `proxy` in "availableWidth:
        // proxy.size.width" is provably the SAME proxy bound by the single
        // `GeometryReader` above, not some other proxy in scope.
        #expect(Self.source.contains(
            "Self.tabItemWidth(availableWidth: proxy.size.width, tabCount: workspace.tabs.count)"))
    }

    /// The container and label frames F9 must KEEP untouched.
    @Test func containerAndLabelFramesStayMaxWidthInfinity() {
        // Anchored on the ADJACENCY, which only the real container frame
        // produces; a stray mention of either modifier elsewhere cannot
        // satisfy it.
        #expect(Self.source.contains(".frame(maxWidth: .infinity) .frame(height: Self.barHeight)"))
        // Label inside the item.
        #expect(Self.source.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    /// F9 wraps the strip in a horizontal, indicator-less `ScrollView` plus a
    /// `ScrollViewReader`, and auto-scrolls on selection change with a
    /// centered anchor.
    @Test func scrollViewAndAutoScrollAreWired() {
        #expect(Self.source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(Self.source.contains("ScrollViewReader"))
        // `store.snapshot.selection.tabID` also appears at the unrelated
        // `isSelected` comparison, so a bare `.contains` on it (or on the
        // scroll call alone) is satisfiable by deleting this ENTIRE
        // auto-scroll block and keeping only that comparison. Anchoring the
        // whole `.onChange` → `withAnimation` → `scrollTo` construct as one
        // normalized contiguous chain requires the real block to survive.
        #expect(Self.source.contains(
            ".onChange(of: store.snapshot.selection.tabID) { newValue in withAnimation { scrollProxy.scrollTo(newValue, anchor: .center) } }"))
    }

    /// F9 must not introduce `onDrop(of:delegate:)` — that API deadlocks the
    /// XCTest host (this suite's own hosting attempts hit exactly that class
    /// of hang).
    @Test func neverUsesOnDropOfDelegate() {
        #expect(!Self.source.contains("onDrop(of:"))
    }

    /// The single-tab guard (`workspace.tabs.count > 1`) that hides the bar
    /// entirely stays intact.
    @Test func singleTabGuardIsUnchanged() {
        #expect(Self.source.contains("workspace.tabs.count > 1"))
    }
}
