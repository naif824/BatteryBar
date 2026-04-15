import Foundation
import WebKit

enum ICloudError: LocalizedError {
    case notLoggedIn
    case sessionExpired
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
// URLSession for API calls. WKWebView only for login UI.
// initClient once -> refreshClient ongoing.
// Keeps the header-derived session token separate from the DS web cookie and
// tries accountLogin when FMIP dies, not only when /validate dies.

@MainActor
final class ICloudService: NSObject {
    private let setupEndpoint = "https://setup.icloud.com/setup/ws/1"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"
    private let homeOrigin = "https://www.icloud.com"
    private let homeReferer = "https://www.icloud.com/"
    private let findReferer = "https://www.icloud.com/find"

    private var dsid: String?
    private var findMeRoot: String?
    private var lastValidation: Date?
    private var sessionEstablished = false

    private let revalidationInterval: TimeInterval = 3600

    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage

    override init() {
        cookieStorage = HTTPCookieStorage.shared
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)

        super.init()

        let saved = CookiePersistence.load()
        for cookie in saved {
            cookieStorage.setCookie(cookie)
        }
        if !saved.isEmpty {
            log("Restored \(saved.count) cookies into URLSession")
        }
    }

    // MARK: - Auth token management

    func saveAuthTokens(
        sessionToken: String?,
        sessionTokenSource: String? = nil,
        trustToken: String?,
        scnt: String?,
        sessionId: String?,
        accountCountry: String? = nil,
        dsWebSessionToken: String? = nil,
        dsid: String? = nil
    ) {
        AuthTokenStore.save(
            sessionToken: sessionToken,
            sessionTokenSource: sessionTokenSource,
            trustToken: trustToken,
            scnt: scnt,
            sessionId: sessionId,
            accountCountry: accountCountry,
            dsWebSessionToken: dsWebSessionToken,
            dsid: dsid
        )
        let tokens = AuthTokenStore.load()
        log(
            "Saved auth state: sessionToken=\(DebugLog.tokenSummary(tokens.sessionToken)), source=\(tokens.sessionTokenSource ?? "nil"), trustToken=\(DebugLog.tokenSummary(tokens.trustToken)), scnt=\(DebugLog.presence(tokens.scnt)), sessionId=\(DebugLog.presence(tokens.sessionId)), accountCountry=\(tokens.accountCountry ?? "nil"), dsWebSessionToken=\(DebugLog.tokenSummary(tokens.dsWebSessionToken)), dsid=\(tokens.dsid ?? "nil")"
        )
    }

    // MARK: - Cookie transfer (WKWebView -> URLSession)

    func importCookiesFromWebView() async {
        let cookies = await sharedWebDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter {
            $0.domain.contains("icloud.com") || $0.domain.contains("apple.com")
        }
        for cookie in relevant {
            cookieStorage.setCookie(cookie)
        }
        saveCookies()
        log("Imported \(relevant.count) cookies from WKWebView to URLSession")

        for cookie in relevant {
            let val = cookie.value.prefix(40)
            log("  Cookie: \(cookie.name) = \(val)... (domain: \(cookie.domain), session-only: \(cookie.expiresDate == nil))")
        }

        if let dsToken = relevant.first(where: { $0.name == "X-APPLE-DS-WEB-SESSION-TOKEN" }) {
            let normalized = normalizedCookieValue(dsToken.value)
            log("  Found X-APPLE-DS-WEB-SESSION-TOKEN cookie \(DebugLog.tokenSummary(normalized))")
            saveAuthTokens(
                sessionToken: nil,
                trustToken: nil,
                scnt: nil,
                sessionId: nil,
                dsWebSessionToken: normalized
            )
        }
    }

    // MARK: - Cookie persistence

    func saveCookies() {
        let all = cookieStorage.cookies ?? []
        let relevant = all.filter {
            $0.domain.contains("icloud.com") || $0.domain.contains("apple.com")
        }
        CookiePersistence.save(relevant)

        let sessionOnly = relevant.filter { $0.expiresDate == nil }
        let persistent = relevant.filter { $0.expiresDate != nil }
        log("Saved \(relevant.count) cookies (session-only: \(sessionOnly.count), persistent: \(persistent.count))")
    }

    // MARK: - API request via URLSession

    private func apiRequest(
        url urlString: String,
        contentType: String,
        body: String,
        referer: String = "https://www.icloud.com/",
        accept: String = "application/json",
        context: String
    ) async throws -> (Int, Data) {
        guard let url = URL(string: urlString) else { throw ICloudError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(homeOrigin, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        log("apiRequest[\(context)]: \(urlString)")

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 0

        log("apiRequest[\(context)] done: HTTP \(status), \(data.count) bytes")

        if let headers = httpResponse?.allHeaderFields {
            captureAuthHeaders(from: headers, context: context)
        }

        if status == 200 {
            let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
                log("apiRequest[\(context)] returned non-JSON; treating as session expired")
                throw ICloudError.sessionExpired
            }
        }

        return (status, data)
    }

    // MARK: - Silent re-authentication via SRP

    /// Attempt silent re-auth using stored Apple ID + password via SRP.
    /// This is the pyicloud approach — creates a brand new session from scratch.
    private func silentReauth(trigger: String) async throws {
        guard let creds = CredentialStore.load() else {
            log("silentReauth[\(trigger)]: no stored credentials")
            throw ICloudError.sessionExpired
        }

        let tokens = AuthTokenStore.load()
        log("silentReauth[\(trigger)]: attempting SRP re-auth for \(creds.appleID)")

        let authService = AppleAuthService(session: session)
        let result = try await authService.silentReauth(
            appleID: creds.appleID,
            password: creds.password,
            storedTrustToken: tokens.trustToken
        )

        // Update stored tokens from the fresh auth
        AuthTokenStore.save(
            sessionToken: result.sessionToken,
            sessionTokenSource: "srp-reauth",
            trustToken: result.trustToken,
            scnt: result.scnt,
            sessionId: result.sessionId,
            accountCountry: result.accountCountry
        )

        extractServiceInfo(from: result.json)
        lastValidation = Date()
        sessionEstablished = false
        saveCookies()
        log("silentReauth[\(trigger)] succeeded via SRP: dsid=\(dsid ?? "nil"), findMeRoot=\(findMeRoot ?? "nil")")
    }

    // MARK: - Validate session

    private var needsRevalidation: Bool {
        guard let last = lastValidation else { return true }
        return Date().timeIntervalSince(last) > revalidationInterval
    }

    func setupSession() async throws {
        let url = "\(setupEndpoint)/validate?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22"
        let (status, data) = try await apiRequest(
            url: url,
            contentType: "text/plain",
            body: "null",
            referer: homeReferer,
            context: "validate"
        )

        log("validate: HTTP \(status)")

        if isAuthStatus(status) {
            dsid = nil
            findMeRoot = nil
            log("validate failed (\(status)), attempting silent re-auth...")
            try await silentReauth(trigger: "validate HTTP \(status)")
            return
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
        saveCookies()
        log("setupSession: dsid=\(dsid ?? "nil"), findMeRoot=\(findMeRoot ?? "nil")")
    }

    private func extractServiceInfo(from json: [String: Any]) {
        var extractedDsid: String?
        var extractedCountry: String?

        if let dsInfo = json["dsInfo"] as? [String: Any] {
            if let id = dsInfo["dsid"] as? String {
                extractedDsid = id
            } else if let id = dsInfo["dsid"] as? Int {
                extractedDsid = String(id)
            }
            if let country = dsInfo["countryCode"] as? String {
                extractedCountry = country
            }
        }
        if let ws = json["webservices"] as? [String: Any],
           let fm = ws["findme"] as? [String: Any],
           let url = fm["url"] as? String {
            findMeRoot = url
        }

        if let extractedDsid {
            dsid = extractedDsid
        }

        saveAuthTokens(
            sessionToken: nil,
            trustToken: nil,
            scnt: nil,
            sessionId: nil,
            accountCountry: extractedCountry,
            dsid: extractedDsid
        )
    }

    // MARK: - Request body

    private let clientContext: [String: Any] = [
        "appName": "iCloud Find (Web)",
        "appVersion": "2.0",
        "apiVersion": "3.0",
        "deviceListVersion": 1,
        "fmly": true,
        "timezone": "US/Pacific",
        "inactiveTime": 0
    ]

    private func fmipRequestBody() throws -> String {
        let body: [String: Any] = ["clientContext": clientContext]
        let data = try JSONSerialization.data(withJSONObject: body)
        return String(data: data, encoding: .utf8)!
    }

    private func fmipUrl(root: String, dsid: String, endpoint: String) -> String {
        "\(root)/fmipservice/client/web/\(endpoint)?clientBuildNumber=2534Project66&clientMasteringNumber=2534B22&dsid=\(dsid)"
    }

    // MARK: - Fetch Devices

    func fetchDevices() async throws -> [Device] {
        log("fetchDevices: sessionEstablished=\(sessionEstablished), needsRevalidation=\(needsRevalidation), hasSession=\(dsid != nil && findMeRoot != nil)")

        if dsid == nil || findMeRoot == nil || needsRevalidation {
            try await setupSession()
        }

        guard let root = findMeRoot, let dsid = dsid else {
            throw ICloudError.notLoggedIn
        }

        let bodyStr = try fmipRequestBody()

        let devices: [Device]
        if sessionEstablished {
            devices = try await callRefreshClient(root: root, dsid: dsid, body: bodyStr)
        } else {
            devices = try await callInitClient(root: root, dsid: dsid, body: bodyStr)
        }

        saveCookies()
        return devices
    }

    // MARK: - initClient (first call, establishes FMIP session)

    private func callInitClient(root: String, dsid: String, body: String, allowRecovery: Bool = true) async throws -> [Device] {
        let url = fmipUrl(root: root, dsid: dsid, endpoint: "initClient")
        let (status, data) = try await apiRequest(
            url: url,
            contentType: "application/json",
            body: body,
            referer: findReferer,
            context: "initClient"
        )
        log("initClient: HTTP \(status)")

        if status >= 400 {
            if let str = String(data: data, encoding: .utf8) {
                log("initClient error: \(String(str.prefix(500)))")
            }

            if allowRecovery && isAuthStatus(status) {
                log("initClient: attempting silent re-auth recovery for HTTP \(status)")
                sessionEstablished = false
                do {
                    try await silentReauth(trigger: "initClient HTTP \(status)")
                    guard let retryRoot = findMeRoot, let retryDsid = self.dsid else {
                        throw ICloudError.sessionExpired
                    }
                    return try await callInitClient(root: retryRoot, dsid: retryDsid, body: body, allowRecovery: false)
                } catch {
                    log("initClient recovery failed: \(error)")
                }
            }

            self.dsid = nil
            self.findMeRoot = nil
            self.lastValidation = nil
            self.sessionEstablished = false
            throw ICloudError.sessionExpired
        }

        let devices = try parseDevices(from: data)
        sessionEstablished = true
        saveCookies()
        log("Session established via initClient")
        return devices
    }

    // MARK: - refreshClient (ongoing updates)

    private func callRefreshClient(root: String, dsid: String, body: String, allowRecovery: Bool = true) async throws -> [Device] {
        let url = fmipUrl(root: root, dsid: dsid, endpoint: "refreshClient")
        let (status, data) = try await apiRequest(
            url: url,
            contentType: "application/json",
            body: body,
            referer: findReferer,
            context: "refreshClient"
        )
        log("refreshClient: HTTP \(status)")

        if status >= 400 {
            if let str = String(data: data, encoding: .utf8) {
                log("refreshClient error: \(String(str.prefix(500)))")
            }

            if allowRecovery && isAuthStatus(status) {
                log("refreshClient: attempting silent re-auth recovery for HTTP \(status)")
                sessionEstablished = false
                do {
                    try await silentReauth(trigger: "refreshClient HTTP \(status)")
                    guard let retryRoot = findMeRoot, let retryDsid = self.dsid else {
                        throw ICloudError.sessionExpired
                    }
                    return try await callInitClient(root: retryRoot, dsid: retryDsid, body: body, allowRecovery: false)
                } catch {
                    log("refreshClient silent re-auth failed: \(error)")
                }
            }

            log("refreshClient failed with \(status), falling back to validate + initClient...")
            self.sessionEstablished = false
            self.dsid = nil
            self.findMeRoot = nil
            self.lastValidation = nil

            do {
                try await setupSession()
                guard let retryRoot = findMeRoot, let retryDsid = self.dsid else {
                    throw ICloudError.sessionExpired
                }
                return try await callInitClient(root: retryRoot, dsid: retryDsid, body: body, allowRecovery: false)
            } catch {
                log("refreshClient validate/init fallback failed: \(error)")
                throw error
            }
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
            throw ICloudError.invalidResponse
        }

        // Log every device's key fields + full dump for iPads
        for d in content {
            let name = d["name"] as? String ?? "?"
            let status = d["deviceStatus"] as? String ?? (d["deviceStatus"].flatMap { "\($0)" } ?? "?")
            let battery = d["batteryLevel"] as? Double
            let batteryStatus = d["batteryStatus"] as? String ?? "?"
            let lowPower = d["lowPowerMode"] as? Bool ?? false
            var locTs = "none"
            if let loc = d["location"] as? [String: Any], let ts = loc["timeStamp"] as? Double, ts > 0 {
                locTs = "\(Int(ts))"
            }
            log("  Device: \(name) | status=\(status) | battery=\(battery.map { String($0) } ?? "nil") | batteryStatus=\(batteryStatus) | lowPower=\(lowPower) | locTimestamp=\(locTs)")

            // Full dump for iPad Mini
            if name.contains("iPad Mini") {
                if let jsonData = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    log("  FULL DUMP [\(name)]:\n\(jsonStr)")
                }
            }
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

        // Show battery for both online and offline devices (last known value)
        let rawLevel = d["batteryLevel"] as? Double
        let percent: Int? = (rawLevel != nil && rawLevel! >= 0)
            ? max(0, min(100, Int((rawLevel! * 100).rounded())))
            : nil
        let charging = (d["batteryStatus"] as? String)?.lowercased() == "charging"
        let lowPower = d["lowPowerMode"] as? Bool ?? false

        // Last seen from location timestamp
        var lastSeen: Date? = nil
        if let location = d["location"] as? [String: Any],
           let ts = location["timeStamp"] as? Double, ts > 0 {
            lastSeen = Date(timeIntervalSince1970: ts / 1000.0)
        }

        return Device(
            id: id, name: name,
            kind: classify(display: display, cls: cls),
            batteryLevel: percent, isCharging: charging, lowPowerMode: lowPower,
            isReachable: isOnline,
            lastSeenTimestamp: lastSeen
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

    // MARK: - Public accessors

    /// Expose URLSession for use by AppleAuthService
    var urlSession: URLSession { session }

    /// Apply auth result from SRP login
    func applyAuthResult(_ result: AuthResult) {
        extractServiceInfo(from: result.json)
        lastValidation = Date()
        sessionEstablished = false
        saveCookies()
        log("Applied auth result: dsid=\(dsid ?? "nil"), findMeRoot=\(findMeRoot ?? "nil")")
    }

    // MARK: - Clear

    func clearSession() {
        dsid = nil
        findMeRoot = nil
        lastValidation = nil
        sessionEstablished = false
        log("Cleared in-memory session state")
    }

    func clearCookies() {
        let cookies = cookieStorage.cookies ?? []
        for cookie in cookies {
            if cookie.domain.contains("icloud.com") || cookie.domain.contains("apple.com") {
                cookieStorage.deleteCookie(cookie)
            }
        }
        CookiePersistence.clear()
        log("Cleared all iCloud/Apple cookies")
    }

    func clearAuthTokens() {
        AuthTokenStore.clear()
        log("Cleared stored auth tokens")
    }

    var isLoggedIn: Bool { dsid != nil && findMeRoot != nil }

    func noteWakeEvent() {
        let tokens = AuthTokenStore.load()
        let validationAge: String
        if let lastValidation {
            validationAge = String(Int(Date().timeIntervalSince(lastValidation)))
        } else {
            validationAge = "nil"
        }

        log(
            "Wake event: sessionEstablished=\(sessionEstablished), lastValidationAgeSec=\(validationAge), inMemoryDsid=\(dsid ?? "nil"), storedDsid=\(tokens.dsid ?? "nil"), sessionToken=\(DebugLog.tokenSummary(tokens.sessionToken)), tokenSource=\(tokens.sessionTokenSource ?? "nil"), dsWebSessionToken=\(DebugLog.tokenSummary(tokens.dsWebSessionToken)), trustToken=\(DebugLog.tokenSummary(tokens.trustToken)), scnt=\(DebugLog.presence(tokens.scnt)), sessionId=\(DebugLog.presence(tokens.sessionId))"
        )
    }

    // MARK: - Logging helpers

    private func log(_ msg: String) {
        DebugLog.write(msg, category: "ICloud")
    }

    private func normalizedCookieValue(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private func isAuthStatus(_ status: Int) -> Bool {
        [403, 421, 450, 500].contains(status)
    }

    private func headerValue(named target: String, from headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers {
            if String(describing: key).caseInsensitiveCompare(target) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    private func captureAuthHeaders(from headers: [AnyHashable: Any], context: String) {
        let current = AuthTokenStore.load()
        var sessionToken = current.sessionToken
        var sessionTokenSource = current.sessionTokenSource
        var trustToken = current.trustToken
        var scnt = current.scnt
        var sessionId = current.sessionId
        var accountCountry = current.accountCountry
        var dsWebSessionToken = current.dsWebSessionToken
        var updated = false

        if let value = headerValue(named: "X-Apple-Session-Token", from: headers), !value.isEmpty {
            sessionToken = value
            sessionTokenSource = "response-header:\(context)"
            updated = true
            log("\(context): captured X-Apple-Session-Token \(DebugLog.tokenSummary(value))")
        }
        if let value = headerValue(named: "X-Apple-TwoSV-Trust-Token", from: headers), !value.isEmpty {
            trustToken = value
            updated = true
            log("\(context): captured X-Apple-TwoSV-Trust-Token \(DebugLog.tokenSummary(value))")
        }
        if let value = headerValue(named: "scnt", from: headers), !value.isEmpty {
            scnt = value
            updated = true
            log("\(context): captured scnt")
        }
        if let value = headerValue(named: "X-Apple-ID-Session-Id", from: headers), !value.isEmpty {
            sessionId = value
            updated = true
            log("\(context): captured X-Apple-ID-Session-Id")
        }
        if let value = headerValue(named: "X-Apple-ID-Account-Country", from: headers), !value.isEmpty {
            accountCountry = value
            updated = true
            log("\(context): captured X-Apple-ID-Account-Country=\(value)")
        }
        if let cookieHeader = headerValue(named: "Set-Cookie", from: headers),
           let token = extractCookie(named: "X-APPLE-DS-WEB-SESSION-TOKEN", from: cookieHeader) {
            dsWebSessionToken = token
            updated = true
            log("\(context): captured X-APPLE-DS-WEB-SESSION-TOKEN \(DebugLog.tokenSummary(token))")
        }

        if updated {
            AuthTokenStore.save(
                sessionToken: sessionToken,
                sessionTokenSource: sessionTokenSource,
                trustToken: trustToken,
                scnt: scnt,
                sessionId: sessionId,
                accountCountry: accountCountry,
                dsWebSessionToken: dsWebSessionToken,
                dsid: current.dsid
            )
        }
    }

    private func extractCookie(named cookieName: String, from header: String) -> String? {
        let prefix = "\(cookieName)="
        guard let range = header.range(of: prefix) else { return nil }
        let remainder = header[range.upperBound...]
        guard let rawValue = remainder.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        return normalizedCookieValue(String(rawValue))
    }
}
