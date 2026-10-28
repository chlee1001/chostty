import Foundation
import Testing

struct SSHInputOwnershipSourceTests {
    @Test func sshIdentifiersRemainOutsideSwiftInputHandlers() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = macosRoot.appendingPathComponent("Sources/Ghostty/Surface View/SurfaceView_AppKit.swift")
        let source = VirtualTabBarScrollTests.normalize(try String(contentsOf: url, encoding: .utf8))
        let declarations = "private(set) var sshChannel: SSHPaneChannel? @Published var sshStatus: SSHPaneStatus?"
        #expect(source.contains(declarations))
        let attachment = "sshChannel = SSHPaneChannel.attach(baseConfig?.ssh, to: self)"
        #expect(source.components(separatedBy: attachment).count == 2)
        let remainder = source.replacingOccurrences(of: declarations, with: "")
            .replacingOccurrences(of: attachment, with: "")
        let identifiers = try NSRegularExpression(pattern: #"\b(?:ssh[A-Z]\w*|SSH\w*)\b"#)
        #expect(identifiers.numberOfMatches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)) == 0)
    }
}
