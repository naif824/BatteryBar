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
