import AppKit
import SwiftUI
import WebKit

struct FilesPanelHTMLReaderView: View {
    let document: FilesPanelTextDocument
    @Binding private var showsPreview: Bool
    private let wrapsLines: Binding<Bool>
    private let searchQuery: Binding<String>
    private let scrollLine: Binding<Int>
    @State private var externalURL: URL?
    @State private var previewFailure: String?

    init(
        document: FilesPanelTextDocument,
        showsPreview: Binding<Bool> = .constant(true),
        wrapsLines: Binding<Bool> = .constant(false),
        searchQuery: Binding<String> = .constant(""),
        scrollLine: Binding<Int> = .constant(0)
    ) {
        self.document = document
        self._showsPreview = showsPreview
        self.wrapsLines = wrapsLines
        self.searchQuery = searchQuery
        self.scrollLine = scrollLine
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("HTML View", selection: $showsPreview) {
                Text("Preview").tag(true)
                Text("Source").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(8)
            Divider()
            if showsPreview {
                VStack(spacing: 0) {
                    if let externalURL {
                        HStack {
                            Text(externalURL.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Open Link in Browser") {
                                NSWorkspace.shared.open(externalURL)
                                self.externalURL = nil
                            }
                            Button("Dismiss") { self.externalURL = nil }
                        }
                        .padding(8)
                        Divider()
                    }
                    if let previewFailure {
                        VStack(spacing: 12) {
                            Label("Preview Stopped", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(previewFailure).foregroundStyle(.secondary)
                            Button("Reload Preview") { self.previewFailure = nil }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        FilesPanelStaticHTMLView(
                            source: document.text,
                            externalURL: $externalURL,
                            failure: $previewFailure
                        )
                    }
                }
            } else {
                FilesPanelTextReaderView(
                    document: document,
                    wrapsLines: wrapsLines,
                    searchQuery: searchQuery,
                    scrollLine: scrollLine
                )
            }
        }
    }
}

struct FilesPanelStaticHTMLPolicy {
    static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "about" && url.absoluteString == "about:blank"
    }

    static func externalLink(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

private struct FilesPanelStaticHTMLView: NSViewRepresentable {
    let source: String
    @Binding var externalURL: URL?
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(externalURL: $externalURL, failure: $failure) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.installDenyRules(on: view, source: source)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.source != source else { return }
        context.coordinator.installDenyRules(on: view, source: source)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllContentRuleLists()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var source: String?
        private var externalURL: Binding<URL?>
        private var failure: Binding<String?>

        init(externalURL: Binding<URL?>, failure: Binding<String?>) {
            self.externalURL = externalURL
            self.failure = failure
        }

        func installDenyRules(on view: WKWebView, source: String) {
            self.source = source
            let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "kr.co.devch.chostty.reader.static-html",
                encodedContentRuleList: rules
            ) { ruleList, _ in
                Task { @MainActor in
                    guard self.source == source else { return }
                    view.configuration.userContentController.removeAllContentRuleLists()
                    guard let ruleList else {
                        view.loadHTMLString(
                            "<p>HTML preview is unavailable because its security policy could not be installed.</p>",
                            baseURL: nil
                        )
                        return
                    }
                    view.configuration.userContentController.add(ruleList)
                    let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; media-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">"#
                    view.loadHTMLString(policy + source, baseURL: nil)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = FilesPanelStaticHTMLPolicy.externalLink(navigationAction.request.url) {
                externalURL.wrappedValue = url
            }
            decisionHandler(FilesPanelStaticHTMLPolicy.allowsNavigation(navigationAction.request.url) ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failure.wrappedValue = "The preview process stopped unexpectedly."
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            failure.wrappedValue = error.localizedDescription
        }
    }
}
