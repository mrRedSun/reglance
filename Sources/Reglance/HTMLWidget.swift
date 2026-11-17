import AppKit
import SwiftUI
import WebKit

/// An ```html widget: a sandboxed web view, created when the card first appears
/// (LazyVStack in the main window, so off-screen cards cost nothing).
struct HTMLCard: View {
    let source: String
    @State private var activated = false
    @State private var height: CGFloat = 120

    /// Content taller than this scrolls inside the card.
    static let maxHeight: CGFloat = 320

    var body: some View {
        let title = Self.title(of: source)
        WidgetCard(kind: "HTML", title: title) {
            CopyButton(help: "Copy source") { [source as NSString] }
            HeaderButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open large", size: 24) {
                Task { await HTMLWindow.open(source: source, title: title) }
            }
        } content: {
            Group {
                if activated {
                    SandboxedWebView(html: source, height: $height)
                } else {
                    Color.clear
                }
            }
            .frame(height: height)
            .padding(.top, 6)
        }
        .onAppear { activated = true }
    }

    /// The page's `<title>`, if it has one.
    static func title(of html: String) -> String {
        guard let match = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/) else { return "Interactive page" }
        let title = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Interactive page" : title
    }
}

/// Shared sandbox settings (design/widgets.md): JavaScript on, every network/file load
/// blocked by a content rule list, navigation blocked, nothing persisted.
enum WebSandbox {
    private static let rules = """
    [
      {"trigger": {"url-filter": "^https?://", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftp://", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^file:", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}}
    ]
    """
    private static var ruleList: WKContentRuleList?
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static let policy = NavigationPolicy()

    /// Compiled once. Nil if compiling failed; then no page is loaded at all.
    static func networkBlocker() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        let compiled = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "reglance-block-network", encodedContentRuleList: rules)
        ruleList = compiled
        return compiled
    }

    static func makeWebView(blocker: WKContentRuleList, heightHandler: WKScriptMessageHandler?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(blocker)
        if let heightHandler {
            configuration.userContentController.add(heightHandler, name: "height")
            configuration.userContentController.addUserScript(WKUserScript(source: """
                (() => {
                  const post = () => window.webkit.messageHandlers.height.postMessage(
                    Math.ceil(document.documentElement.getBoundingClientRect().height));
                  new ResizeObserver(post).observe(document.documentElement);
                  post();
                })();
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = policy
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        return webView
    }

    /// Allows only the initial `loadHTMLString` (about:blank) and about: frames.
    private final class NavigationPolicy: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}

private struct SandboxedWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let coordinator = context.coordinator
        Task {
            guard let blocker = await WebSandbox.networkBlocker() else { return }
            let webView = WebSandbox.makeWebView(blocker: blocker, heightHandler: coordinator)
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            webView.loadHTMLString(html, baseURL: nil)
            coordinator.webView = webView
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        weak var webView: WKWebView?

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value > 0 else { return }
            let capped = min(max(CGFloat(value), 40), HTMLCard.maxHeight)
            if abs(capped - height.wrappedValue) > 0.5 { height.wrappedValue = capped }
        }
    }
}

/// "Open large": a regular resizable window with the same sandbox.
final class HTMLWindow: NSObject, NSWindowDelegate {
    /// Open windows, released when closed.
    private static var open: [HTMLWindow] = []
    private let window: NSWindow

    private init(window: NSWindow) { self.window = window }

    static func open(source: String, title: String) async {
        guard let blocker = await WebSandbox.networkBlocker() else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let webView = WebSandbox.makeWebView(blocker: blocker, heightHandler: nil)
        window.contentView = webView
        webView.loadHTMLString(source, baseURL: nil)
        let controller = HTMLWindow(window: window)
        window.delegate = controller
        open.append(controller)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
