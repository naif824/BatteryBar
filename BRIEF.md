# BatteryBar — External Review Brief

## About the App

BatteryBar is a macOS menu bar app (bundle ID: `cc.naif.batterybar`) that displays battery levels for all Apple devices linked to an iCloud account. It pulls data from iCloud's Find My service. For AirPods specifically, it reads L/R/Case battery locally via IOBluetooth.

Key design choice: all iCloud API calls are made through a **hidden WKWebView** (page navigations, not URLSession). This avoids CORS and cookie management issues — the WebView handles cookies natively. The login flow opens a visible WKWebView to `icloud.com`, detects auth cookies via polling, then the hidden WebView reuses those cookies for API calls.

Stack: Pure Swift, compiled with `swiftc` (no Xcode project), targets arm64 macOS 13.0+.

Data flow:
1. User signs into icloud.com in a WKWebView
2. Auth cookies (`X-APPLE-WEBAUTH-TOKEN/USER`) detected, persisted to UserDefaults
3. Every 5 minutes: calls `/setup/ws/1/validate` to get DSID + Find My endpoint, then `/fmipservice/client/web/initClient` to fetch all devices
4. On HTTP 450: loads `icloud.com/find` in the hidden WebView hoping the SPA refreshes session cookies, then retries
5. On HTTP 421: throws `.sessionExpired`, prompts re-login

Persistence:
- Config: `~/Library/Application Support/BatteryBarV7/config.json`
- Debug log: `~/Library/Application Support/BatteryBarV7/debug.log`
- Session cookies: UserDefaults (key: `icloudSessionCookies`)

---

## Issue 1: Data Goes Stale After ~24 Hours

**Symptom:** After signing in, battery data loads for all devices without issue. After roughly a day, the data stops updating. No visible error — app appears functional, devices still listed with old values.

## Issue 2: Currently Logged In But Showing Wrong Data

**Symptom:** App shows "logged in" state with devices populated, but MacBook Air displays 100% while the actual level is 80%. The data is frozen from the last successful fetch.

---

## Root Cause Analysis

Both issues stem from the same chain of failures. Here is my analysis — looking for your independent assessment.

### 1. Silent Error Swallowing in refreshDevices()

`AppController.swift` lines 86-98: the catch-all block in `refreshDevices()` catches every error that isn't `.sessionExpired`, writes it to a debug log, and does nothing else. `allDevices` retains whatever was last fetched successfully. The timer keeps firing every 5 minutes, keeps failing, keeps swallowing. The user sees stale data indefinitely with zero indication.

### 2. Incomplete Session Expiry Detection

The code only recognizes two failure modes as session death:
- HTTP 421 from `/validate` → `.sessionExpired`
- HTTP 450 from `initClient` → tries `/find` refresh, then `.sessionExpired` if retry also 450

iCloud's session degradation after 24h doesn't always produce these specific codes. It can return 403, 200 with an HTML auth redirect page, or other unexpected responses. None of these trigger re-auth — they fall into the silent catch-all.

### 3. Cached dsid/findMeRoot Bypasses Re-validation

`ICloudService.swift` lines 186-188: once `dsid` and `findMeRoot` are set from the first `/validate` call, `fetchDevices()` skips re-validation on every subsequent call. These values only clear on explicit `clearSession()` (sign-out or mac wake) or after a 450 response. If the server-side session dies without producing a 450, the code keeps hitting `initClient` with a stale DSID indefinitely.

### 4. Potential isRefreshing Deadlock

`AppController.swift` line 72: `guard !isRefreshing` gates every refresh. If the WKWebView navigation never completes (redirect loop, hidden WebView bad state, etc.), the `await withCheckedContinuation` in `apiRequest()` hangs forever, `isRefreshing` stays `true`, and all future timer ticks silently return. App is permanently dead — no refreshes, no error, no UI feedback.

### 5. Fragile /find Recovery Mechanism

`ICloudService.swift` lines 99-101: the 450 recovery loads `icloud.com/find` and sleeps exactly 5 seconds hoping the SPA's JavaScript refreshes session cookies. If it takes longer, doesn't execute JS properly in a hidden offscreen WebView, or Apple changes anything — recovery silently fails.

### 6. No Staleness Detection

The "Updated X ago" label exists but is easy to miss. There's no max-age check, no warning when data is hours old, no visual degradation. The app looks fully functional while serving day-old data.

### My Belief on Most Likely Failure Path

After ~24h, iCloud's server-side session expires. The timer fires, calls `fetchDevices()`. Since `dsid` is cached, it skips `/validate` and goes straight to `callInitClient()`. The server returns something other than 450 (likely a non-JSON response, a redirect, or an unexpected status code). This throws a generic error (`.serverError`, `.invalidResponse`, or a JSON parsing failure). The error hits the catch-all in `refreshDevices()`, gets logged, and `allDevices` keeps the old snapshot. This repeats every 5 minutes, silently, forever.

The debug log at `~/Library/Application Support/BatteryBarV7/debug.log` should confirm which specific error has been repeating.

---

## Full Codebase

### src/Sources/main.swift

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = MainActor.assumeIsolated { AppController() }
withExtendedLifetime(controller) {
    app.run()
}
```

### src/Sources/AppController.swift

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

        // On launch: try to fetch devices using persistent WKWebView cookies
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
        scheduleTimer()
        icloud.clearSession()  // force re-prepare WebView after wake
        Task { await refreshDevices() }
    }

    // MARK: - Refresh

    private var sessionExpiredNotified = false

    private func refreshDevices() async {
        guard !isRefreshing, config.appleID != nil else { return }
        isRefreshing = true

        do {
            allDevices = try await icloud.fetchDevices()
            lastRefresh = Date()
            sessionExpiredNotified = false  // reset on success
            TelemetryService.shared.devicesRefreshed(allDevices.count)
        } catch let error as ICloudError where error == .sessionExpired {
            // Session expired — open login once, don't loop
            if !sessionExpiredNotified {
                sessionExpiredNotified = true
                signInPressed()
            }
        } catch {
            // Log the error so we can debug
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] refreshDevices error: \(error)\n"
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

        isRefreshing = false
        rebuildMenu()
    }

    // MARK: - Visible devices

    private var visibleDevices: [Device] {
        allDevices.filter { !config.hiddenDeviceIDs.contains($0.id) }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let visible = visibleDevices

        menu.removeAllItems()

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

        // AirPods: try local Bluetooth for L/R/Case battery
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

        // Other devices: cloud battery level
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
                self.config.appleID = "iCloud"
                self.configStore.save(self.config)
                TelemetryService.shared.signedIn()
                Task { @MainActor in
                    // Save ALL cookies (including session-only) right after fresh login
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
        // Also clear persistent WKWebView cookies
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

// MARK: - NSMenuDelegate — rebuild menu each time it opens so timestamp is fresh

extension AppController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            rebuildMenu()
        }
    }
}

// Make ICloudError equatable for the catch pattern
extension ICloudError: Equatable {
    static func == (lhs: ICloudError, rhs: ICloudError) -> Bool {
        switch (lhs, rhs) {
        case (.notLoggedIn, .notLoggedIn): return true
        case (.sessionExpired, .sessionExpired): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.serverError(let a), .serverError(let b)): return a == b
        default: return false
        }
    }
}
```

### src/Sources/ICloudService.swift

```swift
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
```

### src/Sources/Models.swift

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

### src/Sources/AirPodsBattery.swift

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

### src/Sources/Persistence.swift

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

### src/Sources/LoginWindowController.swift

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

### src/Sources/SettingsWindowController.swift

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

### src/Sources/TelemetryService.swift

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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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

### src/build.sh

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE="$ROOT/build/BatteryBar"
APP="$ROOT/dist/BatteryBar.app"
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
