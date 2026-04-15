import AppKit
import WebKit
import Sparkle

@MainActor
final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let icloud = ICloudService()
    private let configStore = ConfigStore()
    private let updaterController: SPUStandardUpdaterController

    private var config: AppConfig
    private var allDevices: [Device] = []
    private var refreshTimer: Timer?
    private var lastRefresh: Date?
    private var settingsController: SettingsWindowController?
    private var isRefreshing = false
    private let airpodsManager = AirPodsBatteryManager()

    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private let staleDataThreshold: TimeInterval = 3600 // 1 hour

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
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
        // Don't clear session — URLSession cookies survive sleep
        DebugLog.write("macDidWake: scheduling immediate refresh", category: "App")
        icloud.noteWakeEvent()
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
            logError("refreshDevices sessionExpired (\(consecutiveFailures)/\(maxConsecutiveFailures))")
            if !sessionExpiredNotified {
                sessionExpiredNotified = true
                signInPressed()
            }
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == -1009 {
            // Network offline — don't count as failure, just wait for connectivity
            logError("Network offline, will retry next cycle")
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
        DebugLog.write(msg, category: "App")
    }

    // MARK: - Clear all web data

    private func clearAllWebData() async {
        await sharedWebDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0)
        )
        HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
        CookiePersistence.clear()
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

        let checkUpdate = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesPressed), keyEquivalent: "u")
        checkUpdate.target = self
        menu.addItem(checkUpdate)

        let about = NSMenuItem(title: "About BatteryBar", action: #selector(aboutPressed), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

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

        // Online/offline dot
        let dot = device.isReachable ? "\u{1F7E2} " : "\u{1F534} "
        str.append(NSAttributedString(string: dot))

        // Text color: normal for online, dimmed for offline
        let textColor: NSColor = device.isReachable ? .labelColor : .secondaryLabelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font
        ]

        // AirPods: prefer local Bluetooth battery, only show last seen if NOT connected locally
        if device.kind == .airpods {
            var text = device.name
            let localInfo = airpodsManager.getBattery(forName: device.name)
            let hasLocalData = localInfo != nil && (localInfo!.left != nil || localInfo!.right != nil || localInfo!.caseBattery != nil)

            if hasLocalData, let info = localInfo {
                var parts: [String] = []
                if let l = info.left { parts.append("L:\(l)%") }
                if let r = info.right { parts.append("R:\(r)%") }
                if let c = info.caseBattery { parts.append("C:\(c)%") }
                text += "  " + parts.joined(separator: " ")
            } else if let level = device.batteryLevel, level > 0 {
                text += "  \(level)%"
            } else {
                text += "  --"
            }
            // Only show last seen if no local Bluetooth connection
            if !hasLocalData && !device.isReachable, let lastSeen = device.lastSeenTimestamp {
                text += "  \(formatLastSeen(lastSeen))"
            }
            str.append(NSAttributedString(string: text, attributes: attrs))
            return str
        }

        // Other devices
        var text = device.name
        if let level = device.batteryLevel, (device.isReachable || level > 0) {
            // Show battery if online, or if offline with a non-zero last known value
            text += "  \(level)%"
        } else {
            text += "  --"
        }
        if device.isCharging { text += " \u{26A1}\u{FE0F}" }
        if device.lowPowerMode { text += " \u{1F7E1}" }

        // Offline: show last seen time, or "offline" if no timestamp
        if !device.isReachable {
            if let lastSeen = device.lastSeenTimestamp {
                text += "  \(formatLastSeen(lastSeen))"
            } else {
                text += "  Offline"
            }
        }

        str.append(NSAttributedString(string: text, attributes: attrs))
        return str
    }

    private func formatLastSeen(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "now" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m)m ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            let m = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
            return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
        }
        let d = Int(elapsed / 86400)
        let h = Int((elapsed.truncatingRemainder(dividingBy: 86400)) / 3600)
        return h > 0 ? "\(d)d \(h)h ago" : "\(d)d ago"
    }

    // MARK: - Sign In

    private var credentialController: CredentialWindowController?

    @objc private func signInPressed() {
        if credentialController != nil { return }
        DebugLog.write("Opening credential sign-in window", category: "App")

        let savedID = CredentialStore.load()?.appleID

        credentialController = CredentialWindowController(
            savedAppleID: savedID,
            onComplete: { [weak self] appleID, password in
                guard let self else { return }
                Task { @MainActor in
                    await self.performSRPLogin(appleID: appleID, password: password)
                }
            },
            onCancel: { [weak self] in
                DebugLog.write("Login cancelled", category: "App")
                self?.credentialController = nil
            }
        )

        NSApp.activate(ignoringOtherApps: true)
        credentialController?.showWindow()
    }

    private func performSRPLogin(appleID: String, password: String) async {
        let authService = AppleAuthService(session: icloud.urlSession)
        let twoFAWindow = TwoFAWindowController()

        do {
            let result = try await authService.authenticate(
                appleID: appleID,
                password: password,
                storedTrustToken: AuthTokenStore.load().trustToken,
                twoFAHandler: {
                    await twoFAWindow.getCode()
                }
            )

            // Save credentials for silent re-auth
            CredentialStore.save(appleID: appleID, password: password)

            // Save auth tokens
            AuthTokenStore.save(
                sessionToken: result.sessionToken,
                sessionTokenSource: "srp-login",
                trustToken: result.trustToken,
                scnt: result.scnt,
                sessionId: result.sessionId,
                accountCountry: result.accountCountry
            )

            // Apply session
            icloud.clearSession()
            icloud.applyAuthResult(result)

            credentialController?.close()
            credentialController = nil
            consecutiveFailures = 0
            sessionExpiredNotified = false
            config.appleID = "iCloud"
            configStore.save(config)
            TelemetryService.shared.signedIn()

            DebugLog.write("SRP login succeeded", category: "App")
            await refreshDevices()

        } catch let error as AuthError where error == .twoFARequired {
            credentialController?.setStatus("Trust token expired. Please sign in again with 2FA.")
            DebugLog.write("SRP login needs 2FA: \(error)", category: "App")
        } catch {
            credentialController?.setStatus("Sign in failed: \(error.localizedDescription)")
            DebugLog.write("SRP login failed: \(error)", category: "App")
        }
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
        DebugLog.write("Sign out requested", category: "App")
        TelemetryService.shared.loggedOut()
        icloud.clearSession()
        icloud.clearCookies()
        icloud.clearAuthTokens()
        CredentialStore.clear()
        Task { await clearAllWebData() }
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
        DebugLog.write("Manual refresh requested", category: "App")
        Task {
            await refreshDevices()
            // Re-open the menu after refresh so user sees updated data
            if let button = statusItem.button {
                button.performClick(nil)
            }
        }
    }

    @objc private func checkForUpdatesPressed() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func aboutPressed() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About BatteryBar"
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))

        // App icon
        if let iconPath = Bundle.main.path(forResource: "icon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            let imageView = NSImageView(frame: NSRect(x: 115, y: 135, width: 64, height: 64))
            imageView.image = icon
            container.addSubview(imageView)
        }

        // App name
        let nameLabel = NSTextField(labelWithString: "BatteryBar")
        nameLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: 110, width: 300, height: 24)
        container.addSubview(nameLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: 90, width: 300, height: 18)
        container.addSubview(versionLabel)

        // Developer
        let devLabel = NSTextField(labelWithString: "Developed by Naif AlQazlan")
        devLabel.font = NSFont.systemFont(ofSize: 12)
        devLabel.alignment = .center
        devLabel.frame = NSRect(x: 0, y: 62, width: 300, height: 18)
        container.addSubview(devLabel)

        // Website link
        let linkLabel = NSTextField(frame: NSRect(x: 0, y: 38, width: 300, height: 18))
        linkLabel.isEditable = false
        linkLabel.isBordered = false
        linkLabel.drawsBackground = false
        linkLabel.isSelectable = true
        linkLabel.allowsEditingTextAttributes = true
        linkLabel.alignment = .center
        let linkString = NSMutableAttributedString(string: "Website")
        linkString.addAttribute(.link, value: URL(string: "https://icamel.app/product/batterybar/")!, range: NSRange(location: 0, length: linkString.length))
        linkString.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: linkString.length))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        linkString.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: linkString.length))
        linkLabel.attributedStringValue = linkString
        container.addSubview(linkLabel)

        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
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
        case (.serverError(let a), .serverError(let b)): return a == b
        default: return false
        }
    }
}
