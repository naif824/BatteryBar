import AppKit
import WebKit

/// Shared persistent data store — survives app restarts, keeps iCloud cookies alive.
let sharedWebDataStore = WKWebsiteDataStore.default()

/// Opens a WKWebView to icloud.com. User signs in via Apple's own UI.
/// Injects JavaScript to intercept XHR responses from idmsa.apple.com
/// and capture auth tokens (session_token, trust_token) for silent re-auth.
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private let onComplete: () -> Void
    private let onCancel: () -> Void
    private var pollTimer: Timer?

    private var preExistingCookieNames: Set<String> = []

    /// Auth tokens captured via JS XHR interception
    private(set) var capturedSessionToken: String?
    private(set) var capturedTrustToken: String?
    private(set) var capturedScnt: String?
    private(set) var capturedSessionId: String?
    private(set) var capturedAccountCountry: String?

    /// JavaScript that monkey-patches XMLHttpRequest to capture auth headers
    /// from idmsa.apple.com responses and send them to Swift via messageHandlers.
    private static let xhrInterceptScript = """
    (function() {
        if (window.__batteryBarInterceptInstalled) return;
        window.__batteryBarInterceptInstalled = true;

        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;

        XMLHttpRequest.prototype.open = function(method, url) {
            this.__bbUrl = url;
            return origOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function() {
            var xhr = this;
            var origHandler = xhr.onreadystatechange;

            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4 && xhr.__bbUrl) {
                    try {
                        var url = xhr.__bbUrl;
                        if (url.indexOf('idmsa.apple.com') !== -1 || url.indexOf('setup.icloud.com') !== -1) {
                            var tokens = {};
                            var st = xhr.getResponseHeader('X-Apple-Session-Token');
                            if (st) tokens.sessionToken = st;
                            var tt = xhr.getResponseHeader('X-Apple-TwoSV-Trust-Token');
                            if (tt) tokens.trustToken = tt;
                            var sc = xhr.getResponseHeader('scnt');
                            if (sc) tokens.scnt = sc;
                            var sid = xhr.getResponseHeader('X-Apple-ID-Session-Id');
                            if (sid) tokens.sessionId = sid;
                            var ac = xhr.getResponseHeader('X-Apple-ID-Account-Country');
                            if (ac) tokens.accountCountry = ac;

                            if (Object.keys(tokens).length > 0) {
                                tokens.sourceUrl = url;
                                window.webkit.messageHandlers.authTokens.postMessage(JSON.stringify(tokens));
                            }
                        }
                    } catch(e) {}
                }
                if (origHandler) origHandler.apply(this, arguments);
            };

            // Also handle onload for fetch-style XHR usage
            xhr.addEventListener('load', function() {
                if (xhr.__bbUrl) {
                    try {
                        var url = xhr.__bbUrl;
                        if (url.indexOf('idmsa.apple.com') !== -1 || url.indexOf('setup.icloud.com') !== -1) {
                            var tokens = {};
                            var st = xhr.getResponseHeader('X-Apple-Session-Token');
                            if (st) tokens.sessionToken = st;
                            var tt = xhr.getResponseHeader('X-Apple-TwoSV-Trust-Token');
                            if (tt) tokens.trustToken = tt;
                            var sc = xhr.getResponseHeader('scnt');
                            if (sc) tokens.scnt = sc;
                            var sid = xhr.getResponseHeader('X-Apple-ID-Session-Id');
                            if (sid) tokens.sessionId = sid;
                            var ac = xhr.getResponseHeader('X-Apple-ID-Account-Country');
                            if (ac) tokens.accountCountry = ac;

                            if (Object.keys(tokens).length > 0) {
                                tokens.sourceUrl = url;
                                window.webkit.messageHandlers.authTokens.postMessage(JSON.stringify(tokens));
                            }
                        }
                    } catch(e) {}
                }
            });

            return origSend.apply(this, arguments);
        };

        // Also intercept fetch API
        var origFetch = window.fetch;
        window.fetch = function() {
            var url = arguments[0];
            if (typeof url === 'object' && url.url) url = url.url;
            return origFetch.apply(this, arguments).then(function(response) {
                try {
                    var urlStr = typeof url === 'string' ? url : '';
                    if (urlStr.indexOf('idmsa.apple.com') !== -1 || urlStr.indexOf('setup.icloud.com') !== -1) {
                        var tokens = {};
                        var st = response.headers.get('X-Apple-Session-Token');
                        if (st) tokens.sessionToken = st;
                        var tt = response.headers.get('X-Apple-TwoSV-Trust-Token');
                        if (tt) tokens.trustToken = tt;
                        var sc = response.headers.get('scnt');
                        if (sc) tokens.scnt = sc;
                        var sid = response.headers.get('X-Apple-ID-Session-Id');
                        if (sid) tokens.sessionId = sid;
                        var ac = response.headers.get('X-Apple-ID-Account-Country');
                        if (ac) tokens.accountCountry = ac;

                        if (Object.keys(tokens).length > 0) {
                            tokens.sourceUrl = urlStr;
                            window.webkit.messageHandlers.authTokens.postMessage(JSON.stringify(tokens));
                        }
                    }
                } catch(e) {}
                return response;
            });
        };
    })();
    """

    init(onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        let config = WKWebViewConfiguration()
        config.websiteDataStore = sharedWebDataStore

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Inject XHR interceptor before any page scripts run
        let userScript = WKUserScript(
            source: LoginWindowController.xhrInterceptScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false  // Also inject in iframes (idmsa auth runs in iframe)
        )
        let contentController = config.userContentController
        contentController.addUserScript(userScript)

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

        // Register message handler for receiving intercepted tokens from JS
        config.userContentController.add(LeakAvoider(delegate: self), name: "authTokens")

        window.delegate = self
        webView.navigationDelegate = self
    }

    func showWindow() {
        Task {
            let cookies = await sharedWebDataStore.httpCookieStore.allCookies()
            preExistingCookieNames = Set(cookies.map { "\($0.name)_\($0.domain)" })
            log("Showing login window with \(cookies.count) pre-existing cookies")

            let url = URL(string: "https://www.icloud.com")!
            webView.load(URLRequest(url: url))
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        log("Closing login window")
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        log("Login window closed by user")
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

        let authCookies = cookies.filter {
            $0.name == "X-APPLE-WEBAUTH-TOKEN" || $0.name == "X-APPLE-WEBAUTH-USER"
        }

        let hasNewAuthCookie = authCookies.contains { cookie in
            !preExistingCookieNames.contains("\(cookie.name)_\(cookie.domain)")
        }

        if hasNewAuthCookie {
            let hasDSWebCookie = cookies.contains { $0.name == "X-APPLE-DS-WEB-SESSION-TOKEN" }
            log(
                "Detected new auth cookies; authCookies=\(authCookies.count), dsWebCookie=\(hasDSWebCookie ? "yes" : "no"), sessionToken=\(DebugLog.tokenSummary(capturedSessionToken)), trustToken=\(DebugLog.tokenSummary(capturedTrustToken))"
            )
            pollTimer?.invalidate()
            pollTimer = nil
            onComplete()
        }
    }
}

// MARK: - WKScriptMessageHandler (receives intercepted auth tokens from JS)

/// Weak reference wrapper to avoid retain cycle with WKUserContentController
private class LeakAvoider: NSObject, WKScriptMessageHandler {
    weak var delegate: LoginWindowController?

    init(delegate: LoginWindowController) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            delegate?.handleAuthTokenMessage(message)
        }
    }
}

extension LoginWindowController {
    func handleAuthTokenMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }

        let source = json["sourceUrl"] ?? "unknown"

        if let v = json["sessionToken"] {
            capturedSessionToken = v
            log("Captured sessionToken from \(source) \(DebugLog.tokenSummary(v))")
        }
        if let v = json["trustToken"] {
            capturedTrustToken = v
            log("Captured trustToken from \(source) \(DebugLog.tokenSummary(v))")
        }
        if let v = json["scnt"] {
            capturedScnt = v
            log("Captured scnt from \(source)")
        }
        if let v = json["sessionId"] {
            capturedSessionId = v
            log("Captured sessionId from \(source)")
        }
        if let v = json["accountCountry"] {
            capturedAccountCountry = v
            log("Captured accountCountry=\(v) from \(source)")
        }
    }

    private func log(_ msg: String) {
        DebugLog.write(msg, category: "Login")
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
