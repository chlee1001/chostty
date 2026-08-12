import Foundation
import Testing
@testable import Ghostty

struct FilesPanelHTMLPolicyTests {
    @Test func allowsOnlyInternalBlankNavigation() {
        #expect(FilesPanelStaticHTMLPolicy.allowsNavigation(URL(string: "about:blank")))
        #expect(!FilesPanelStaticHTMLPolicy.allowsNavigation(URL(string: "https://example.com")))
        #expect(!FilesPanelStaticHTMLPolicy.allowsNavigation(URL(fileURLWithPath: "/tmp/secret")))
        #expect(!FilesPanelStaticHTMLPolicy.allowsNavigation(URL(string: "data:text/html,test")))
        #expect(!FilesPanelStaticHTMLPolicy.allowsNavigation(nil))
    }

    @Test func exposesOnlyHTTPLinksForExplicitExternalOpen() {
        #expect(FilesPanelStaticHTMLPolicy.externalLink(URL(string: "https://example.com")) != nil)
        #expect(FilesPanelStaticHTMLPolicy.externalLink(URL(string: "http://example.com")) != nil)
        #expect(FilesPanelStaticHTMLPolicy.externalLink(URL(fileURLWithPath: "/tmp/secret")) == nil)
        #expect(FilesPanelStaticHTMLPolicy.externalLink(URL(string: "javascript:alert(1)")) == nil)
    }
}
