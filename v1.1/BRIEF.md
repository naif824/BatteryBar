# BatteryBar v2.0 — Changes Brief

## About the App

BatteryBar is a macOS menu bar app (bundle ID: `cc.naif.batterybar`) that displays battery levels for all Apple devices linked to an iCloud account. It pulls data from iCloud's Find My service via a hidden WKWebView (page navigations, not URLSession — avoids CORS/cookie issues). For AirPods, it reads L/R/Case battery locally via IOBluetooth.

Stack: Pure Swift, compiled with `swiftc` (no Xcode project), targets arm64 macOS 13.0+.

---

## Issues in v1.0

### Issue 1: Data Goes Stale After ~24 Hours

After signing in, battery data loads for all devices without issue. After roughly a day, the data stops updating. No visible error — app appears functional, devices still listed with old values.

### Issue 2: Logged In But Showing Wrong Data

App shows "logged in" state with devices populated, but displays stale battery percentages (e.g., MacBook Air at 100% when actually 80%). Data is frozen from the last successful fetch.

---

## Root Cause Analysis

Both issues stem from the same chain of failures:

1. **Silent error swallowing** — `refreshDevices()` caught every non-`.sessionExpired` error, logged it to a file, and did nothing. `allDevices` retained the last successful fetch indefinitely. Timer kept firing, kept failing, kept swallowing.

2. **Narrow session expiry detection** — Only HTTP 421 (from `/validate`) and 450 (from `initClient`) triggered re-auth. iCloud session degradation after ~24h often produces 403, 200 with HTML auth redirect, or other unexpected responses. None of these triggered re-login.

3. **Cached `dsid`/`findMeRoot` never re-validated** — Once set from the first `/validate` call, `fetchDevices()` skipped re-validation forever. If the server-side session died without a 450, the code kept hitting `initClient` with stale context.

4. **`isRefreshing` deadlock risk** — If WKWebView navigation never completed (redirect loop, hidden WebView bad state), `withCheckedContinuation` hung forever, `isRefreshing` stayed `true`, and all future refreshes silently returned at the guard.

5. **No staleness visibility** — The "Updated X ago" label existed but was passive. No warning when data was hours old.

---

## What Changed in v2.0

Only two files were modified: `ICloudService.swift` and `AppController.swift`.

### ICloudService.swift — 4 fixes

**1. Navigation timeout (fixes deadlock risk)**

Added `navigateWithTimeout()` that wraps every `webView.load()` + continuation in a 30-second race via `withTaskGroup`. If the WKWebView never calls `didFinish`/`didFail`, the timeout fires, resumes the continuation, stops the WebView, and throws `.navigationTimeout`. This prevents `isRefreshing` from locking permanently.

```swift
private func navigateWithTimeout(_ request: URLRequest) async throws {
    capturedStatusCode = 0
    webView.load(request)

    let didComplete = await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor in
            await withCheckedContinuation { ... }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(self.navigationTimeout * 1_000_000_000))
            return false
        }
        let result = await group.next()!
        group.cancelAll()
        return result
    }

    if !didComplete {
        navigationContinuation?.resume()
        navigationContinuation = nil
        webView.stopLoading()
        throw ICloudError.navigationTimeout
    }
}
```

**2. Periodic re-validation (fixes stale DSID caching)**

Added `lastValidation` timestamp and `needsRevalidation` check. `fetchDevices()` now calls `setupSession()` every hour instead of only when `dsid` is nil:

```swift
// v1.0 — only re-validates when dsid is nil (effectively never after first success)
if dsid == nil || findMeRoot == nil {
    try await setupSession()
}

// v2.0 — re-validates every hour
if dsid == nil || findMeRoot == nil || needsRevalidation {
    try await setupSession()
}
```

**3. Broader session expiry detection**

- `setupSession()`: 421, 450, AND 403 all throw `.sessionExpired`. Any `>= 400` clears cached dsid/findMeRoot. JSON parse failure also clears them.
- `callInitClient()`: ANY `>= 400` status clears cached session and throws `.sessionExpired` (not just 450).
- `apiRequest()`: Detects HTML auth pages masquerading as HTTP 200 — checks response body for `<!doctype`, `<html`, `sign in`, `appleid.apple.com` and throws `.sessionExpired`.
- `parseDevices()`: Now throws `.invalidResponse` on missing/empty `content` instead of silently returning `[]`.

**4. New `.navigationTimeout` error case**

Added to `ICloudError` enum so timeouts propagate correctly through the error handling chain.

### AppController.swift — 3 fixes

**1. Consecutive failure tracking with escalation**

Tracks `consecutiveFailures`. After 3 silent failures, forces `clearSession()` + opens login prompt. Resets on success, wake, or fresh sign-in:

```swift
} catch {
    consecutiveFailures += 1
    logError("refreshDevices error (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(error)")

    if consecutiveFailures >= maxConsecutiveFailures && !sessionExpiredNotified {
        sessionExpiredNotified = true
        icloud.clearSession()
        signInPressed()
    }
}
```

**2. `defer { isRefreshing = false }`**

Guarantees the flag resets even on unexpected throws. v1.0 set it at the end of the method — if an unexpected code path threw, it could stay `true` forever.

**3. Staleness UI in menu**

- Orange "Data may be outdated" label when `lastRefresh > 1 hour`
- "Refresh failing (Nx)" label when consecutive failures are happening but old data is still displayed

### Files NOT changed

`main.swift`, `Models.swift`, `Persistence.swift`, `LoginWindowController.swift`, `SettingsWindowController.swift`, `AirPodsBattery.swift`, `TelemetryService.swift` — all unchanged from v1.0.

---

## Full v2.0 Codebase

### src/Sources/main.swift (unchanged)

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = MainActor.assumeIsolated { AppController() }
withExtendedLifetime(controller) {
    app.run()
}
```

### src/Sources/AppController.swift (CHANGED)

```swift
import AppKit
import WebKit

@MainActor
final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let icloud = ICloudService()
    private let configStore = ConfigStore()

    private var config: AppConfig
    private var allDevices: [Device] = []
    private var refreshTimer: Timer?
    private var lastRefresh: Date?
    private var loginController: LoginWindowController?
    private var settingsController: SettingsWindowController?
    private var isRefreshing = false
    private let airpodsManager = AirPodsBatteryManager()

    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private let staleDataThreshold: TimeInterval = 3600 // 1 hour

    override init() {
        config = configStore.load()
        super.init()

        setupStatusIcon()
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()
        scheduleTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(macDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        TelemetryService.shared.appLaunched()

        if config.appleID != nil {
            Task { await refreshDevices() }
        }
    }

    // MARK: - Status bar icon

    private func setupStatusIcon() {
        guard let button = statusItem.button else { return }
        button.title = "\u{1F50B}"
        button.image = nil
    }

    // MARK: - Timer

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshDevices() }
        }
    }

    @objc private func macDidWake() {
        consecutiveFailures = 0
        scheduleTimer()
        icloud.clearSession()
        Task { await refreshDevices() }
    }

    // MARK: - Refresh

    private var sessionExpiredNotified = false

    private func refreshDevices() async {
        guard !isRefreshing, config.appleID != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            allDevices = try await icloud.fetchDevices()
            lastRefresh = Date()
            consecutiveFailures = 0
            sessionExpiredNotified = false
            TelemetryService.shared.devicesRefreshed(allDevices.count)
        } catch let error as ICloudError where error == .sessionExpired {
            consecutiveFailures += 1
            if !sessionExpiredNotified {
                sessionExpiredNotified = true
                signInPressed()
            }
        } catch {
            consecutiveFailures += 1
            logError("refreshDevices error (\(consecutiveFailures)/\(maxConsecutiveFailures)): \(error)")

            // After repeated failures, escalate to session expired
            if consecutiveFailures >= maxConsecutiveFailures && !sessionExpiredNotified {
                sessionExpiredNotified = true
                icloud.clearSession()
                signInPressed()
            }
        }

        rebuildMenu()
    }

    private func logError(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BatteryBarV7")
        let logPath = dir.appendingPathComponent("debug.log")
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - Staleness

    private var isDataStale: Bool {
        guard let lastRefresh else { return false }
        return Date().timeIntervalSince(lastRefresh) > staleDataThreshold
    }

    // MARK: - Visible devices

    private var visibleDevices: [Device] {
        allDevices.filter { !config.hiddenDeviceIDs.contains($0.id) }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let visible = visibleDevices

        menu.removeAllItems()

        // Staleness warning
        if isDataStale {
            let warn = makeLabel("Data may be outdated")
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
            warn.attributedTitle = NSAttributedString(string: "Data may be outdated", attributes: attrs)
            menu.addItem(warn)
            menu.addItem(NSMenuItem.separator())
        }

        if consecutiveFailures > 0 && !allDevices.isEmpty {
            let failLabel = makeLabel("Refresh failing (\(consecutiveFailures)x)")
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
            failLabel.attributedTitle = NSAttributedString(string: "Refresh failing (\(consecutiveFailures)x)", attributes: attrs)
            menu.addItem(failLabel)
            menu.addItem(NSMenuItem.separator())
        }

        if allDevices.isEmpty {
            let msg = config.appleID == nil ? "Sign in to see your devices" : "No devices"
            menu.addItem(makeLabel(msg))
        } else if visible.isEmpty {
            menu.addItem(makeLabel("All devices hidden (check Settings)"))
        } else {
            let sorted = visible.sorted {
                if $0.isReachable != $1.isReachable { return $0.isReachable }
                return ($0.batteryLevel ?? 999) < ($1.batteryLevel ?? 999)
            }
            for device in sorted {
                let item = NSMenuItem()
                item.attributedTitle = formatDevice(device)
                menu.addItem(item)
            }
        }

        if let lastRefresh {
            menu.addItem(NSMenuItem.separator())
            let formatter = RelativeDateTimeFormatter()
            let label = formatter.localizedString(for: lastRefresh, relativeTo: Date())
            menu.addItem(makeLabel("Updated \(label)"))
        }

        menu.addItem(NSMenuItem.separator())

        if config.appleID != nil {
            let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshPressed), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)

            let settings = NSMenuItem(title: "Visible Devices...", action: #selector(settingsPressed), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)

            menu.addItem(NSMenuItem.separator())

            let signOut = NSMenuItem(title: "Sign Out", action: #selector(signOutPressed), keyEquivalent: "")
            signOut.target = self
            menu.addItem(signOut)
        } else {
            let signIn = NSMenuItem(title: "Sign In to iCloud...", action: #selector(signInPressed), keyEquivalent: "i")
            signIn.target = self
            menu.addItem(signIn)
        }

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitPressed), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeLabel(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func formatDevice(_ device: Device) -> NSAttributedString {
        let str = NSMutableAttributedString()

        let dot = device.isReachable ? "\u{1F7E2} " : "\u{1F534} "
        str.append(NSAttributedString(string: dot))

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        ]

        if device.kind == .airpods {
            var text = device.name
            if let info = airpodsManager.getBattery(forName: device.name) {
                var parts: [String] = []
                if let l = info.left { parts.append("L:\(l)%") }
                if let r = info.right { parts.append("R:\(r)%") }
                if let c = info.caseBattery { parts.append("C:\(c)%") }
                if !parts.isEmpty {
                    text += "  " + parts.joined(separator: " ")
                } else {
                    text += "  --"
                }
            } else {
                text += "  --"
            }
            str.append(NSAttributedString(string: text, attributes: attrs))
            return str
        }

        var text = device.name
        if let level = device.batteryLevel {
            text += "  \(level)%"
        } else {
            text += "  --"
        }
        if device.isCharging { text += " \u{26A1}" }
        if device.lowPowerMode { text += " LP" }

        str.append(NSAttributedString(string: text, attributes: attrs))

        return str
    }

    // MARK: - Sign In

    @objc private func signInPressed() {
        if loginController != nil { return }

        loginController = LoginWindowController(
            onComplete: { [weak self] in
                guard let self else { return }
                self.loginController?.close()
                self.loginController = nil
                self.icloud.clearSession()
                self.consecutiveFailures = 0
                self.sessionExpiredNotified = false
                self.config.appleID = "iCloud"
                self.configStore.save(self.config)
                TelemetryService.shared.signedIn()
                Task { @MainActor in
                    await self.icloud.saveCookies()
                    await self.refreshDevices()
                }
            },
            onCancel: { [weak self] in
                self?.loginController = nil
            }
        )

        NSApp.activate(ignoringOtherApps: true)
        loginController?.showWindow()
    }

    // MARK: - Settings

    @objc private func settingsPressed() {
        if settingsController != nil {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        settingsController = SettingsWindowController(
            devices: allDevices,
            hiddenIDs: config.hiddenDeviceIDs,
            onSave: { [weak self] hiddenIDs in
                guard let self else { return }
                self.config.hiddenDeviceIDs = hiddenIDs
                self.configStore.save(self.config)
                self.rebuildMenu()
            },
            onClose: { [weak self] in
                self?.settingsController = nil
            }
        )

        TelemetryService.shared.settingsOpened()
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow()
    }

    // MARK: - Sign Out

    @objc private func signOutPressed() {
        TelemetryService.shared.loggedOut()
        icloud.clearSession()
        CookiePersistence.clear()
        Task {
            let store = sharedWebDataStore
            let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            let icloudRecords = records.filter {
                $0.displayName.contains("icloud") || $0.displayName.contains("apple")
            }
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: icloudRecords)
        }
        config.appleID = nil
        configStore.save(config)
        allDevices = []
        lastRefresh = nil
        consecutiveFailures = 0
        sessionExpiredNotified = false
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func refreshPressed() {
        Task { await refreshDevices() }
    }

    @objc private func quitPressed() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            rebuildMenu()
        }
    }
}

extension ICloudError: Equatable {
    static func == (lhs: ICloudError, rhs: ICloudError) -> Bool {
        switch (lhs, rhs) {
        case (.notLoggedIn, .notLoggedIn): return true
        case (.sessionExpired, .sessionExpired): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.navigationTimeout, .navigationTimeout): return true
        case (.serverError(let a), .serverError(let b)): return a == b
        default: return false
        }
    }
}
```

### src/Sources/ICloudService.swift (CHANGED)

```swift
import Foundation
import WebKit

enum ICloudError: LocalizedError {
    case notLoggedIn
    case sessionExpired
    case invalidResponse
    case serverError(Int)
    case navigationTimeout

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not signed in to iCloud."
        case .sessionExpired: return "Session expired. Please sign in again."
        case .invalidResponse: return "Unexpected response from iCloud."
        case .serverError(let code): return "iCloud returned HTTP \(code)."
        case .navigationTimeout: return "Request timed out."
        }
    }
}

// MARK: - iCloud Find My Service

@MainActor
final class ICloudService: NSObject {
    private let setupEndpoint = "https://setup.icloud.com/setup/ws/1"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"

    private var dsid: String?
    private var findMeRoot: String?
    private var lastValidation: Date?

    private let webView: WKWebView
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) private var capturedStatusCode: Int = 0
    private var cookiesRestored = false

    /// Re-validate session if last validation was more than this many seconds ago
    private let revalidationInterval: TimeInterval = 3600 // 1 hour

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

    func saveCookies() async {
        let cookies = await sharedWebDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter {
            $0.domain.contains("icloud.com") || $0.domain.contains("apple.com")
        }
        CookiePersistence.save(relevant)
        log("Saved \(relevant.count) cookies to persistence")

        let sessionOnly = relevant.filter { $0.expiresDate == nil }
        let persistent = relevant.filter { $0.expiresDate != nil }
        log("  Session-only: \(sessionOnly.count) [\(sessionOnly.map { $0.name }.joined(separator: ", "))]")
        log("  Persistent: \(persistent.count)")
    }

    // MARK: - Refresh session via /find

    private func refreshViaFindMy() async {
        log("Refreshing session via /find...")

        do {
            try await navigateWithTimeout(URLRequest(url: URL(string: "https://www.icloud.com/find")!))
        } catch {
            log("  /find navigation failed: \(error)")
            return
        }

        log("  /find page loaded, waiting for SPA init...")
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        await saveCookies()
        log("  /find refresh complete")
    }

    // MARK: - Navigation with timeout

    private let navigationTimeout: TimeInterval = 30

    private func navigateWithTimeout(_ request: URLRequest) async throws {
        capturedStatusCode = 0
        webView.load(request)

        let didComplete = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.navigationContinuation = c
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.navigationTimeout * 1_000_000_000))
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }

        if !didComplete {
            log("Navigation timed out after \(Int(navigationTimeout))s")
            navigationContinuation?.resume()
            navigationContinuation = nil
            webView.stopLoading()
            throw ICloudError.navigationTimeout
        }
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

        log("apiRequest: \(urlString)")
        try await navigateWithTimeout(request)

        let status = capturedStatusCode

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

        // Detect HTML auth redirects masquerading as 200
        if status == 200 || status == 0 {
            let snippet = bodyText.prefix(200).lowercased()
            if snippet.contains("<!doctype") || snippet.contains("<html") || snippet.contains("sign in") || snippet.contains("appleid.apple.com") {
                log("Response looks like HTML auth page, treating as session expired")
                throw ICloudError.sessionExpired
            }
        }

        return (status, data)
    }

    // MARK: - Validate session

    private var needsRevalidation: Bool {
        guard let last = lastValidation else { return true }
        return Date().timeIntervalSince(last) > revalidationInterval
    }

    func setupSession() async throws {
        let url = "\(setupEndpoint)/validate?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22"
        let (status, data) = try await apiRequest(url: url, contentType: "text/plain", body: "null")

        log("validate: HTTP \(status)")

        if status == 421 || status == 450 || status == 403 {
            dsid = nil
            findMeRoot = nil
            throw ICloudError.sessionExpired
        }
        if status >= 400 {
            dsid = nil
            findMeRoot = nil
            throw ICloudError.serverError(status)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("validate: could not parse JSON, body: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "nil")")
            dsid = nil
            findMeRoot = nil
            throw ICloudError.invalidResponse
        }

        extractServiceInfo(from: json)
        lastValidation = Date()
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
        // Re-validate periodically instead of caching dsid/findMeRoot forever
        if dsid == nil || findMeRoot == nil || needsRevalidation {
            try await setupSession()
        }

        guard let root = findMeRoot, let dsid = dsid else {
            throw ICloudError.notLoggedIn
        }

        let devices = try await callInitClient(root: root, dsid: dsid)

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

        // Any 4xx → clear cached session and attempt recovery
        if status >= 400 {
            self.dsid = nil
            self.findMeRoot = nil
            self.lastValidation = nil

            if status == 450 {
                log("initClient got 450 — attempting /find refresh...")
                await refreshViaFindMy()

                try await setupSession()

                guard let retryRoot = findMeRoot, let retryDsid = self.dsid else {
                    throw ICloudError.sessionExpired
                }

                let retryUrl = "\(retryRoot)/fmipservice/client/web/initClient?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22&dsid=\(retryDsid)"
                let (retryStatus, retryData) = try await apiRequest(url: retryUrl, contentType: "application/json", body: bodyStr)
                log("initClient retry: HTTP \(retryStatus)")

                if retryStatus >= 400 {
                    throw ICloudError.sessionExpired
                }
                return try parseDevices(from: retryData)
            }

            // 421, 403, or any other client/server error
            if let str = String(data: data, encoding: .utf8) {
                log("initClient error: \(String(str.prefix(500)))")
            }
            throw ICloudError.sessionExpired
        }

        return try parseDevices(from: data)
    }

    // MARK: - Parse

    private func parseDevices(from data: Data) throws -> [Device] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            log("No 'content' in response")
            if let str = String(data: data, encoding: .utf8) {
                log("Response: \(String(str.prefix(500)))")
            }
            // Missing content means the response isn't valid Find My data
            throw ICloudError.invalidResponse
        }

        guard !content.isEmpty else {
            log("'content' array is empty")
            throw ICloudError.invalidResponse
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
        lastValidation = nil
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
```

### src/Sources/Models.swift (unchanged)

```swift
import Foundation

enum DeviceKind: String, Codable {
    case iPhone, iPad, watch, mac, airpods, other

    var label: String {
        switch self {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .watch: return "Watch"
        case .mac: return "Mac"
        case .airpods: return "AirPods"
        case .other: return "Device"
        }
    }

    var emoji: String {
        switch self {
        case .iPhone: return "\u{1F4F1}"
        case .iPad: return "\u{1F4F1}"
        case .watch: return "\u{231A}"
        case .mac: return "\u{1F4BB}"
        case .airpods: return "\u{1F3A7}"
        case .other: return "\u{1F50B}"
        }
    }
}

struct Device {
    let id: String
    let name: String
    let kind: DeviceKind
    let batteryLevel: Int?       // nil = unknown/offline
    let isCharging: Bool
    let lowPowerMode: Bool
    let isReachable: Bool        // deviceStatus == "200" or location present
}

struct AppConfig: Codable {
    var appleID: String?
    var refreshInterval: TimeInterval = 300
    var hiddenDeviceIDs: [String] = []
}
```

### src/Sources/AirPodsBattery.swift (unchanged)

```swift
import Foundation
import IOBluetooth

struct AirPodsBatteryInfo {
    let left: Int?
    let right: Int?
    let caseBattery: Int?
    let isConnected: Bool
}

/// Reads AirPods battery levels from local Bluetooth (IOBluetooth private API).
/// Only works when AirPods are paired/connected to this Mac.
final class AirPodsBatteryManager {

    /// Get battery info for AirPods matching a given name (case-insensitive partial match).
    func getBattery(forName name: String) -> AirPodsBatteryInfo? {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil
        }

        let lower = name.lowercased()
        guard let device = devices.first(where: {
            ($0.name ?? "").lowercased().contains(lower) ||
            ($0.name ?? "").lowercased().contains("airpods")
        }) else {
            return nil
        }

        return readBattery(from: device)
    }

    /// Get battery info for all paired AirPods-like devices.
    func getAllAirPods() -> [String: AirPodsBatteryInfo] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return [:]
        }

        var result: [String: AirPodsBatteryInfo] = [:]
        for device in devices {
            guard let name = device.name, name.lowercased().contains("airpods") else { continue }
            result[name] = readBattery(from: device)
        }
        return result
    }

    private func readBattery(from device: IOBluetoothDevice) -> AirPodsBatteryInfo {
        let left = readSelector("batteryPercentLeft", from: device)
        let right = readSelector("batteryPercentRight", from: device)
        let caseBat = readSelector("batteryPercentCase", from: device)

        return AirPodsBatteryInfo(
            left: left,
            right: right,
            caseBattery: caseBat,
            isConnected: device.isConnected()
        )
    }

    private func readSelector(_ name: String, from device: IOBluetoothDevice) -> Int? {
        let sel = Selector(name)
        guard device.responds(to: sel) else { return nil }
        let result = device.perform(sel)
        let value = Int(bitPattern: result?.toOpaque())
        // IOBluetooth returns 0 or -1 for unknown; valid range is 1–100
        return (value > 0 && value <= 100) ? value : nil
    }
}
```

### src/Sources/Persistence.swift (unchanged)

```swift
import Foundation
import Security

// MARK: - Config Store

final class ConfigStore {
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BatteryBarV7")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    func save(_ config: AppConfig) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Cookie Persistence (saves session-only cookies that WKWebsiteDataStore drops)

final class CookiePersistence {
    private static let key = "icloudSessionCookies"

    static func save(_ cookies: [HTTPCookie]) {
        let dicts = cookies.compactMap { cookie -> [String: Any]? in
            guard let props = cookie.properties else { return nil }
            var d: [String: Any] = [:]
            for (k, v) in props { d[k.rawValue] = v }
            return d
        }
        UserDefaults.standard.set(dicts, forKey: key)
    }

    static func load() -> [HTTPCookie] {
        guard let dicts = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return dicts.compactMap { dict in
            let props = Dictionary(uniqueKeysWithValues: dict.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            return HTTPCookie(properties: props)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Keychain Helper

final class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "com.batterybar.v7"

    func save(account: String, password: String) {
        delete(account: account)
        guard let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

### src/Sources/LoginWindowController.swift (unchanged)

```swift
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
```

### src/Sources/SettingsWindowController.swift (unchanged)

```swift
import AppKit

/// Settings window with checkboxes to show/hide devices.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let scrollView: NSScrollView
    private let stackView: NSStackView
    private var checkboxes: [(NSButton, String)] = [] // (checkbox, deviceID)

    private let onSave: ([String]) -> Void // returns hidden device IDs
    private let onClose: () -> Void

    init(devices: [Device], hiddenIDs: [String], onSave: @escaping ([String]) -> Void, onClose: @escaping () -> Void) {
        self.onSave = onSave
        self.onClose = onClose

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = stackView
        scrollView.contentView = clipView

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Visible Devices"
        window.isReleasedWhenClosed = false

        let container = NSView()
        container.addSubview(scrollView)

        super.init()
        window.delegate = self
        window.contentView = container

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        // Build checkboxes
        let header = NSTextField(labelWithString: "Select devices to show in menu:")
        header.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(header)

        for device in devices {
            let title = "\(device.kind.emoji)  \(device.name)"
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged))
            cb.state = hiddenIDs.contains(device.id) ? .off : .on
            cb.font = NSFont.systemFont(ofSize: 13)
            stackView.addArrangedSubview(cb)
            checkboxes.append((cb, device.id))
        }

        // Size stack to fit
        NSLayoutConstraint.activate([
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -20),
        ])

        window.center()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func checkboxChanged() {
        let hidden = checkboxes.filter { $0.0.state == .off }.map { $0.1 }
        onSave(hidden)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
```

### src/Sources/TelemetryService.swift (unchanged)

```swift
import Foundation
import CryptoKit

final class TelemetryService {
    static let shared = TelemetryService()
    private init() {}

    private let appID = "016A0883-097A-4443-8B1B-1566E84296F2"
    private let endpoint = "https://nom.telemetrydeck.com/v2/"
    private let sessionID = UUID().uuidString
    private lazy var userID: String = {
        let key = "cc.naif.batterybar.telemetryUserID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private var hashedUser: String {
        let data = Data(userID.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func send(_ signalName: String, payload: [String: String] = [:]) {
        let signal: [String: Any] = [
            "appID": appID,
            "clientUser": hashedUser,
            "sessionID": sessionID,
            "type": signalName,
            "payload": payload
        ]

        guard let url = URL(string: endpoint),
              let data = try? JSONSerialization.data(withJSONObject: [signal]) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func appLaunched() { send("appLaunched") }

    func signedIn() { send("signedIn") }

    func devicesRefreshed(_ count: Int) {
        send("devicesRefreshed", payload: ["deviceCount": "\(count)"])
    }

    func settingsOpened() { send("settingsOpened") }

    func loggedOut() { send("loggedOut") }
}
```

### src/Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>cc.naif.batterybar</string>
    <key>CFBundleName</key>
    <string>BatteryBar</string>
    <key>CFBundleDisplayName</key>
    <string>BatteryBar</string>
    <key>CFBundleExecutable</key>
    <string>BatteryBar</string>
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>BatteryBar reads AirPods battery levels via Bluetooth.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
```

### build.sh

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$ROOT/build/BatteryBar"
APP="$ROOT/dist/BatteryBar v2.0.app"
IDENTITY="Developer ID Application: Naif AlQazlan (9VRVCKY375)"

echo "Compiling BatteryBar..."
SDK=$(xcrun --show-sdk-path --sdk macosx)
swiftc -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -O \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  -framework WebKit \
  -framework IOBluetooth \
  "$ROOT"/Sources/*.swift \
  -o "$EXECUTABLE"

echo "Packaging app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/BatteryBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Copy app icon
ICON="$ROOT/../icon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/icon.icns"
fi

echo "Signing with hardened runtime..."
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "Done: $APP"
```
