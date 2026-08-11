import SwiftUI

@MainActor
protocol MarkdownRenderer {
    func render(_ document: FilesPanelMarkdownDocument) -> AnyView
}
