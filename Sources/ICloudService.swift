import Foundation
import WebKit

enum ICloudError: LocalizedError {
    case notLoggedIn
    case sessionExpired  // 450 — needs re-login via WKWebView
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not signed in to iCloud."
        case .sessionExpired: return "Session expired. Please sign in again."
        case .invalidResponse: return "Unexpected response from iCloud."
        case .serverError(let code): return "iCloud returned HTTP \(code)."
        }
    }
}

// MARK: - iCloud Find My Service
// API calls are WKWebView page navigations (POST). No CORS, no cookie transfer.
// Session-only cookies are manually persisted + refreshed via /find on 450.

@MainActor
final class ICloudService: NSObject {
    private let setupEndpoint = "https://setup.icloud.com/setup/ws/1"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"

    private var dsid: String?
    private var findMeRoot: String?

    /// Hidden WKWebView — API calls are page navigations (POST).
    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) private var capturedStatusCode: Int = 0
    private var cookiesRestored = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = sharedWebDataStore
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent

        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Cookie management

    /// Restore manually-saved cookies (including session-only ones) into the WKWebsiteDataStore.
    func restoreCookies() async {
        if cookiesRestored { return }
        cookiesRestored = true

        let saved = CookiePersistence.load()
        guard !saved.isEmpty else {
            log("No saved cookies to restore")
            return
        }

        let store = sharedWebDataStore.httpCookieStore
        for cookie in saved {
            await store.setCookie(cookie)
        }
        log("Restored \(saved.count) cookies from persistence")
    }

    /// Save ALL current cookies (including session-only) to UserDefaults.
    func saveCookies() async {
        let cookies = await sharedWebDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter {
            $0.domain.contains("icloud.com") || $0.domain.contains("apple.com")
        }
        CookiePersistence.save(relevant)
        log("Saved \(relevant.count) cookies to persistence")

        // Log session-only vs persistent for debugging
        let sessionOnly = relevant.filter { $0.expiresDate == nil }
        let persistent = relevant.filter { $0.expiresDate != nil }
        log("  Session-only: \(sessionOnly.count) [\(sessionOnly.map { $0.name }.joined(separator: ", "))]")
        log("  Persistent: \(persistent.count)")
    }

    // MARK: - Refresh session via /find (re-creates session cookies)

    /// Loads icloud.com/find in the hidden WKWebView. The Find My SPA calls initClient
    /// internally, which causes the server to send fresh Set-Cookie headers.
    private func refreshViaFindMy() async {
        log("Refreshing session via /find...")
        webView.load(URLRequest(url: URL(string: "https://www.icloud.com/find")!))

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            navigationContinuation = c
        }

        // Wait for the SPA to initialize and make its own initClient call
        log("  /find page loaded, waiting for SPA init...")
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        // Save the refreshed cookies
        await saveCookies()
        log("  /find refresh complete")
    }

    // MARK: - Navigation-based API request

    private func apiRequest(url urlString: String, contentType: String, body: String) async throws -> (Int, Data) {
        await restoreCookies()

        guard let url = URL(string: urlString) else { throw ICloudError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.icloud.com/find", forHTTPHeaderField: "Referer")

        capturedStatusCode = 0
        log("apiRequest: \(urlString)")
        webView.load(request)

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            navigationContinuation = c
        }

        let status = capturedStatusCode

        // Read response body rendered in the page
        var bodyText = ""
        do {
            if let text = try await webView.evaluateJavaScript(
                "document.body ? (document.querySelector('pre') ? document.querySelector('pre').textContent : document.body.innerText) : ''"
            ) as? String {
                bodyText = text
            }
        } catch {
            log("evaluateJavaScript error: \(error)")
        }

        let data = bodyText.data(using: .utf8) ?? Data()
        log("apiRequest done: HTTP \(status), \(data.count) bytes")

        return (status, data)
    }

    // MARK: - Validate session

    func setupSession() async throws {
        let url = "\(setupEndpoint)/validate?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22"
        let (status, data) = try await apiRequest(url: url, contentType: "text/plain", body: "null")

        log("validate: HTTP \(status)")

        if status == 421 { throw ICloudError.sessionExpired }
        if status >= 400 { throw ICloudError.serverError(status) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("validate: could not parse JSON, body: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "nil")")
            throw ICloudError.invalidResponse
        }

        extractServiceInfo(from: json)
        log("setupSession: dsid=\(dsid ?? "nil"), findMeRoot=\(findMeRoot ?? "nil")")
    }

    private func extractServiceInfo(from json: [String: Any]) {
        if let dsInfo = json["dsInfo"] as? [String: Any] {
            if let id = dsInfo["dsid"] as? String { dsid = id }
            else if let id = dsInfo["dsid"] as? Int { dsid = String(id) }
        }
        if let ws = json["webservices"] as? [String: Any],
           let fm = ws["findme"] as? [String: Any],
           let url = fm["url"] as? String {
            findMeRoot = url
        }
    }

    // MARK: - Fetch Devices

    func fetchDevices() async throws -> [Device] {
        if dsid == nil || findMeRoot == nil {
            try await setupSession()
        }

        guard let root = findMeRoot, let dsid = dsid else {
            throw ICloudError.notLoggedIn
        }

        let devices = try await callInitClient(root: root, dsid: dsid)

        // Success — save cookies so session-only ones survive next restart
        await saveCookies()

        return devices
    }

    private func callInitClient(root: String, dsid: String) async throws -> [Device] {
        let requestBody: [String: Any] = [
            "clientContext": [
                "appName": "iCloud Find (Web)",
                "appVersion": "2.0",
                "apiVersion": "3.0",
                "deviceListVersion": 1,
                "fmly": true,
                "timezone": "US/Pacific",
                "inactiveTime": 0
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        let bodyStr = String(data: bodyData, encoding: .utf8)!
        let url = "\(root)/fmipservice/client/web/initClient?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22&dsid=\(dsid)"

        let (status, data) = try await apiRequest(url: url, contentType: "application/json", body: bodyStr)
        log("initClient: HTTP \(status)")

        if status == 450 {
            // Try refreshing session via /find, then retry ONCE
            log("initClient got 450 — attempting /find refresh...")
            await refreshViaFindMy()

            // Clear session info and re-validate with fresh cookies
            self.dsid = nil
            self.findMeRoot = nil
            try await setupSession()

            guard let retryRoot = findMeRoot, let retryDsid = self.dsid else {
                throw ICloudError.sessionExpired
            }

            let retryUrl = "\(retryRoot)/fmipservice/client/web/initClient?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22&dsid=\(retryDsid)"
            let (retryStatus, retryData) = try await apiRequest(url: retryUrl, contentType: "application/json", body: bodyStr)
            log("initClient retry: HTTP \(retryStatus)")

            if retryStatus == 450 {
                throw ICloudError.sessionExpired
            }
            if retryStatus >= 400 {
                throw ICloudError.serverError(retryStatus)
            }
            return parseDevices(from: retryData)
        }

        if status >= 400 {
            if let str = String(data: data, encoding: .utf8) {
                log("initClient error: \(String(str.prefix(500)))")
            }
            throw ICloudError.serverError(status)
        }

        return parseDevices(from: data)
    }

    // MARK: - Parse

    private func parseDevices(from data: Data) -> [Device] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            log("No 'content' in response")
            if let str = String(data: data, encoding: .utf8) {
                log("Response: \(String(str.prefix(500)))")
            }
            return []
        }

        log("Got \(content.count) devices from Find My")
        return content.compactMap(mapDevice)
    }

    private func mapDevice(_ d: [String: Any]) -> Device? {
        guard let id = d["id"] as? String else { return nil }
        let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (d["deviceDisplayName"] as? String) ?? "Device"
        let display = d["deviceDisplayName"] as? String ?? ""
        let cls = d["deviceClass"] as? String ?? ""
        let statusRaw = d["deviceStatus"] as? String ?? (d["deviceStatus"].flatMap { "\($0)" } ?? "")
        let isOnline = statusRaw == "200"

        let rawLevel = d["batteryLevel"] as? Double
        // Only show battery if device is online and has a valid level (> 0 or exactly 0 while online)
        let percent: Int? = (isOnline && rawLevel != nil && rawLevel! >= 0)
            ? max(0, min(100, Int((rawLevel! * 100).rounded())))
            : nil
        let charging = isOnline && (d["batteryStatus"] as? String)?.lowercased() == "charging"
        let lowPower = isOnline && (d["lowPowerMode"] as? Bool ?? false)

        return Device(
            id: id, name: name,
            kind: classify(display: display, cls: cls),
            batteryLevel: percent, isCharging: charging, lowPowerMode: lowPower,
            isReachable: isOnline
        )
    }

    private func classify(display: String, cls: String) -> DeviceKind {
        let s = "\(display) \(cls)".lowercased()
        if s.contains("iphone") { return .iPhone }
        if s.contains("ipad") { return .iPad }
        if s.contains("watch") { return .watch }
        if s.contains("airpods") { return .airpods }
        if s.contains("mac") || s.contains("book") || s.contains("imac") { return .mac }
        return .other
    }

    // MARK: - Clear

    func clearSession() {
        dsid = nil
        findMeRoot = nil
        cookiesRestored = false
    }

    var isLoggedIn: Bool { dsid != nil && findMeRoot != nil }

    // MARK: - Logging

    private func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BatteryBarV7")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logPath = dir.appendingPathComponent("debug.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path),
               let handle = try? FileHandle(forWritingTo: logPath) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logPath, options: .atomic)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension ICloudService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            capturedStatusCode = http.statusCode
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navigationContinuation?.resume()
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navigationContinuation?.resume()
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navigationContinuation?.resume()
            navigationContinuation = nil
        }
    }
}
