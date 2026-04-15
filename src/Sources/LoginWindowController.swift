import AppKit
import WebKit

/// Shared persistent data store — survives app restarts, keeps iCloud cookies alive.
let sharedWebDataStore = WKWebsiteDataStore.default()

/// Opens a WKWebView to icloud.com. User signs in via Apple's own UI.
/// Cookies stay in the shared persistent store — no extraction needed.
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private let onComplete: () -> Void
    private let onCancel: () -> Void
    private var pollTimer: Timer?

    init(onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        // Use the persistent shared data store — cookies survive app restarts
        let config = WKWebViewConfiguration()
        config.websiteDataStore = sharedWebDataStore

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign In to iCloud"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false

        super.init()
        window.delegate = self
        webView.navigationDelegate = self
    }

    func showWindow() {
        let url = URL(string: "https://www.icloud.com")!
        webView.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        onCancel()
    }

    private func startCookiePolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.checkForAuthCookies() }
        }
    }

    private func checkForAuthCookies() async {
        let cookies = await sharedWebDataStore.httpCookieStore.allCookies()
        let hasWebAuthToken = cookies.contains { $0.name == "X-APPLE-WEBAUTH-TOKEN" }
        let hasWebAuthUser = cookies.contains { $0.name == "X-APPLE-WEBAUTH-USER" }

        if hasWebAuthToken || hasWebAuthUser {
            pollTimer?.invalidate()
            pollTimer = nil
            onComplete()
        }
    }
}

// MARK: - WKNavigationDelegate

extension LoginWindowController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            startCookiePolling()
            await checkForAuthCookies()
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
}
