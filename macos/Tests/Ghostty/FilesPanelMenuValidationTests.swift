import Foundation
import Testing

struct FilesPanelMenuValidationTests {
    @Test func viewMenuItemHasNoReservedShortcutAndTargetsAppDelegate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuURL = root.appendingPathComponent("Sources/App/macOS/MainMenu.xib")
        let source = try String(contentsOf: menuURL, encoding: .utf8)
        let itemStart = try #require(source.range(of: "<menuItem title=\"Show Files Panel\""))
        let itemTail = source[itemStart.lowerBound...]
        let itemEnd = try #require(itemTail.range(of: "</menuItem>"))
        let item = itemTail[..<itemEnd.upperBound]

        #expect(item.contains("selector=\"toggleFilesPanel:\""))
        #expect(!item.contains("keyEquivalent=\""))
    }

    @Test func appDelegateDisablesMenuWithoutOrdinaryControllerCapability() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delegateURL = root.appendingPathComponent("Sources/App/macOS/AppDelegate.swift")
        let source = try String(contentsOf: delegateURL, encoding: .utf8)

        #expect(source.contains("case #selector(toggleFilesPanel(_:))"))
        #expect(source.contains("let filesPanelController = controller.filesPanelController else"))
        #expect(source.contains("item.title = \"Show Files Panel\"\n                return false"))
    }
}
