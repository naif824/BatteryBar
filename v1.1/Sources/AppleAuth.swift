import Foundation

// MARK: - Apple iCloud Authentication
// Matches pyicloud's exact flow:
// Step 0: GET /authorize/signin (gets cookies, scnt, session_id, auth_attributes)
// Step 1: POST /signin/init (SRP init with client public key A)
// Step 2: POST /signin/complete (SRP proof M1/M2)
// Step 3: 2FA if needed (409)
// Step 4: POST /accountLogin (exchange session token for iCloud session)

@MainActor
final class AppleAuthService {
    private let authEndpoint = "https://idmsa.apple.com/appleauth/auth"
    private let setupEndpoint = "https://setup.icloud.com/setup/ws/1"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"
    private let widgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"
    private let clientId: String

    private let session: URLSession

    private var scnt: String?
    private var sessionId: String?
    private var sessionToken: String?
    private var trustToken: String?
    private var accountCountry: String?
    private var authAttributes: String?

    init(session: URLSession) {
        self.session = session
        self.clientId = UUID().uuidString.lowercased()
    }

    // MARK: - Full Authentication (with 2FA UI)

    func authenticate(
        appleID: String,
        password: String,
        storedTrustToken: String?,
        twoFAHandler: @escaping () async -> String?
    ) async throws -> AuthResult {
        log("Starting authentication for \(appleID)")

        // Step 0: Get auth page cookies + headers
        try await authorizeSignin()

        // Steps 1-2: SRP signin
        let status = try await srpSignin(
            appleID: appleID,
            password: password,
            trustToken: storedTrustToken
        )

        if status == 409 {
            log("2FA required — requesting auth options + sending SMS")
            let phoneInfo = try await requestMFAOptions()
            if let phone = phoneInfo {
                try await requestSMSCode(phoneNumber: phone)
                log("SMS code requested")
            }
            guard let code = await twoFAHandler() else {
                throw AuthError.twoFACancelled
            }
            if let phone = phoneInfo {
                try await verifySMSCode(code, phoneNumber: phone)
            } else {
                try await submit2FACode(code)
            }
            try await requestTrustToken()
        }

        guard let sessionToken = self.sessionToken else {
            throw AuthError.noSessionToken
        }

        return try await accountLogin(sessionToken: sessionToken)
    }

    /// Silent re-auth (no UI)
    func silentReauth(
        appleID: String,
        password: String,
        storedTrustToken: String?
    ) async throws -> AuthResult {
        log("Attempting silent re-auth for \(appleID)")

        try await authorizeSignin()

        let status = try await srpSignin(
            appleID: appleID,
            password: password,
            trustToken: storedTrustToken
        )

        if status == 409 {
            log("Silent re-auth needs 2FA — trust token expired")
            throw AuthError.twoFARequired
        }

        guard let sessionToken = self.sessionToken else {
            throw AuthError.noSessionToken
        }

        return try await accountLogin(sessionToken: sessionToken)
    }

    // MARK: - Step 0: Authorize/Signin GET (gets cookies + session headers)

    private func authorizeSignin() async throws {
        var components = URLComponents(string: "\(authEndpoint)/authorize/signin")!
        components.queryItems = [
            URLQueryItem(name: "frame_id", value: clientId),
            URLQueryItem(name: "skVersion", value: "7"),
            URLQueryItem(name: "iframeid", value: clientId),
            URLQueryItem(name: "client_id", value: widgetKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: "https://www.icloud.com"),
            URLQueryItem(name: "response_mode", value: "web_message"),
            URLQueryItem(name: "state", value: clientId),
            URLQueryItem(name: "authVersion", value: "latest"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.icloud.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        log("authorize/signin: GET")
        let (_, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        log("authorize/signin: HTTP \(status)")

        // Capture session headers
        if let s = http?.value(forHTTPHeaderField: "scnt") { scnt = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") { sessionId = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-Auth-Attributes") { authAttributes = s }

        log("authorize/signin: scnt=\(DebugLog.presence(scnt)), sessionId=\(DebugLog.presence(sessionId)), authAttributes=\(DebugLog.presence(authAttributes))")
    }

    // MARK: - Steps 1-2: SRP Signin

    private func srpSignin(appleID: String, password: String, trustToken: String?) async throws -> Int {
        let srp = AppleSRPClient(username: appleID, password: password)
        let (a, A) = srp.generateClientCredentials()

        // Step 1: signin/init
        let aBase64 = A.serialize().base64EncodedString()
        let initBody: [String: Any] = [
            "a": aBase64,
            "accountName": appleID,
            "protocols": ["s2k", "s2k_fo"]
        ]

        let (initStatus, initData, _) = try await authRequest(
            path: "/signin/init",
            body: initBody,
            context: "signin/init"
        )

        guard initStatus == 200 else {
            log("signin/init failed: HTTP \(initStatus)")
            if let body = String(data: initData, encoding: .utf8) {
                log("signin/init response: \(body.prefix(300))")
            }
            throw AuthError.signinFailed(initStatus)
        }

        guard let initJson = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let b = initJson["b"] as? String,
              let salt = initJson["salt"] as? String,
              let iterations = initJson["iteration"] as? Int,
              let proto = initJson["protocol"] as? String,
              let c = initJson["c"] as? String
        else {
            throw AuthError.invalidResponse("signin/init")
        }

        log("signin/init: protocol=\(proto), iterations=\(iterations)")

        // Step 2: Compute SRP proof and complete
        let serverB = BigUInt(Data(base64Encoded: b)!)
        let saltData = Data(base64Encoded: salt)!
        let (M1, M2) = srp.computeProof(
            a: a, A: A,
            serverB: serverB,
            salt: saltData,
            iterations: iterations,
            protocol: proto,
            serverC: c
        )

        var completeBody: [String: Any] = [
            "accountName": appleID,
            "m1": M1.base64EncodedString(),
            "m2": M2.base64EncodedString(),
            "c": c,
            "rememberMe": true
        ]
        if let trustToken, !trustToken.isEmpty {
            completeBody["trustTokens"] = [trustToken]
        }

        let (completeStatus, completeData, _) = try await authRequest(
            path: "/signin/complete?isRememberMeEnabled=true",
            body: completeBody,
            context: "signin/complete"
        )

        if let body = String(data: completeData, encoding: .utf8) {
            log("signin/complete response (\(completeStatus)): \(body.prefix(300))")
        }

        if completeStatus == 200 {
            log("signin/complete: success")
        } else if completeStatus == 409 {
            log("signin/complete: 2FA required")
        } else if completeStatus == 401 || completeStatus == 403 {
            log("signin/complete: auth rejected (\(completeStatus))")
            throw AuthError.signinFailed(completeStatus)
        } else {
            throw AuthError.signinFailed(completeStatus)
        }

        return completeStatus
    }

    // MARK: - 2FA

    /// Request MFA auth options — returns trusted phone number info for SMS
    private func requestMFAOptions() async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: authEndpoint)!)
        request.httpMethod = "GET"
        addCommonHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        log("requestMFAOptions: GET \(authEndpoint)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        log("requestMFAOptions: HTTP \(status), \(data.count) bytes")

        if let http = response as? HTTPURLResponse {
            if let s = http.value(forHTTPHeaderField: "scnt") { scnt = s }
            if let s = http.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") { sessionId = s }
            if let s = http.value(forHTTPHeaderField: "X-Apple-Auth-Attributes") { authAttributes = s }
        }

        // Parse response to find trusted phone number
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            log("MFA options: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")

            // Look for trustedPhoneNumbers in the response
            if let phoneVerification = json["phoneNumberVerification"] as? [String: Any],
               let phoneNumber = phoneVerification["trustedPhoneNumber"] as? [String: Any] {
                log("Found trusted phone: \(phoneNumber)")
                return phoneNumber
            }

            // Alternative: trustedPhoneNumbers array
            if let phones = json["trustedPhoneNumbers"] as? [[String: Any]], let first = phones.first {
                log("Found trusted phone from array: \(first)")
                return first
            }
        }

        log("No trusted phone number found in MFA options")
        return nil
    }

    /// Request SMS code delivery
    private func requestSMSCode(phoneNumber: [String: Any]) async throws {
        // pyicloud sends only {id, nonFTEU} — not the full phone object
        var phonePayload: [String: Any] = [:]
        if let id = phoneNumber["id"] { phonePayload["id"] = id }
        if let nonFTEU = phoneNumber["nonFTEU"] { phonePayload["nonFTEU"] = nonFTEU }

        let body: [String: Any] = [
            "phoneNumber": phonePayload,
            "mode": "sms"
        ]

        let (status, data, _) = try await authRequest(
            path: "/verify/phone",
            method: "PUT",
            body: body,
            context: "request-sms"
        )

        if let responseBody = String(data: data, encoding: .utf8) {
            log("request-sms response (\(status)): \(responseBody.prefix(300))")
        }
    }

    /// Verify SMS code
    private func verifySMSCode(_ code: String, phoneNumber: [String: Any]) async throws {
        var phonePayload: [String: Any] = [:]
        if let id = phoneNumber["id"] { phonePayload["id"] = id }
        if let nonFTEU = phoneNumber["nonFTEU"] { phonePayload["nonFTEU"] = nonFTEU }

        let pushMode = phoneNumber["pushMode"] as? String ?? "sms"
        let body: [String: Any] = [
            "phoneNumber": phonePayload,
            "securityCode": ["code": code],
            "mode": pushMode
        ]

        let (status, data, _) = try await authRequest(
            path: "/verify/phone/securitycode",
            body: body,
            context: "verify-sms"
        )

        if let responseBody = String(data: data, encoding: .utf8) {
            log("verify-sms response (\(status)): \(responseBody.prefix(300))")
        }

        guard status == 200 || status == 204 else {
            throw AuthError.twoFAFailed(status)
        }

        log("SMS code verified")
    }

    private func submit2FACode(_ code: String) async throws {
        let body: [String: Any] = [
            "securityCode": ["code": code]
        ]

        let (status, data, _) = try await authRequest(
            path: "/verify/trusteddevice/securitycode",
            body: body,
            context: "verify/securitycode"
        )

        if let body = String(data: data, encoding: .utf8) {
            log("2FA response (\(status)): \(body.prefix(300))")
        }

        guard status == 204 || status == 200 else {
            throw AuthError.twoFAFailed(status)
        }

        log("2FA code accepted")
    }

    private func requestTrustToken() async throws {
        let url = "\(authEndpoint)/2sv/trust"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        addCommonHeaders(to: &request)

        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if let trust = http.value(forHTTPHeaderField: "X-Apple-TwoSV-Trust-Token") {
                self.trustToken = trust
                log("Got trust token")
            }
            if let token = http.value(forHTTPHeaderField: "X-Apple-Session-Token") {
                self.sessionToken = token
            }
        }
    }

    // MARK: - Account Login

    private func accountLogin(sessionToken: String) async throws -> AuthResult {
        var body: [String: Any] = [
            "dsWebAuthToken": sessionToken,
            "extended_login": true
        ]
        if let trustToken = self.trustToken {
            body["trustToken"] = trustToken
        }
        if let country = self.accountCountry {
            body["accountCountryCode"] = country
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "\(setupEndpoint)/accountLogin")!)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.icloud.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        log("accountLogin: posting")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        log("accountLogin: HTTP \(status)")

        if let responseBody = String(data: data, encoding: .utf8) {
            log("accountLogin response: \(responseBody.prefix(500))")
        }

        guard status == 200 else {
            throw AuthError.accountLoginFailed(status)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("accountLogin")
        }

        return AuthResult(
            json: json,
            sessionToken: sessionToken,
            trustToken: self.trustToken,
            scnt: self.scnt,
            sessionId: self.sessionId,
            accountCountry: self.accountCountry
        )
    }

    // MARK: - HTTP helpers

    private func authRequest(
        path: String,
        method: String = "POST",
        body: [String: Any],
        context: String
    ) async throws -> (Int, Data, [AnyHashable: Any]) {
        let url = "\(authEndpoint)\(path)"
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = bodyData
        addCommonHeaders(to: &request)

        log("\(context): \(method) \(url)")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = http?.allHeaderFields ?? [:]

        // Capture auth state from every response
        if let s = http?.value(forHTTPHeaderField: "scnt") { scnt = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") { sessionId = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-ID-Account-Country") { accountCountry = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-Session-Token") { sessionToken = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-TwoSV-Trust-Token") { trustToken = s }
        if let s = http?.value(forHTTPHeaderField: "X-Apple-Auth-Attributes") { authAttributes = s }

        log("\(context): HTTP \(status), \(data.count) bytes")
        return (status, data, headers)
    }

    private func addCommonHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
        request.setValue("https://idmsa.apple.com", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(widgetKey, forHTTPHeaderField: "X-Apple-OAuth-Client-Id")
        request.setValue("firstPartyAuth", forHTTPHeaderField: "X-Apple-OAuth-Client-Type")
        request.setValue("true", forHTTPHeaderField: "X-Apple-OAuth-Require-Grant-Code")
        request.setValue("code", forHTTPHeaderField: "X-Apple-OAuth-Response-Type")
        request.setValue("https://www.icloud.com", forHTTPHeaderField: "X-Apple-OAuth-Redirect-URI")
        request.setValue("web_message", forHTTPHeaderField: "X-Apple-OAuth-Response-Mode")
        request.setValue(clientId, forHTTPHeaderField: "X-Apple-OAuth-State")
        request.setValue(clientId, forHTTPHeaderField: "X-Apple-Frame-Id")
        request.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")

        let fdClientInfo = "{\"U\":\"\(userAgent)\",\"L\":\"en-US\",\"Z\":\"GMT+00:00\",\"V\":\"1.1\",\"F\":\"\"}"
        request.setValue(fdClientInfo, forHTTPHeaderField: "X-Apple-FD-Client-Info")

        if let scnt = scnt {
            request.setValue(scnt, forHTTPHeaderField: "scnt")
        }
        if let sessionId = sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        }
        if let authAttributes = authAttributes {
            request.setValue(authAttributes, forHTTPHeaderField: "X-Apple-Auth-Attributes")
        }
    }

    private func log(_ msg: String) {
        DebugLog.write(msg, category: "Auth")
    }
}

// MARK: - Auth Result

struct AuthResult {
    let json: [String: Any]
    let sessionToken: String
    let trustToken: String?
    let scnt: String?
    let sessionId: String?
    let accountCountry: String?
}

// MARK: - Auth Errors

enum AuthError: LocalizedError, Equatable {
    static func == (lhs: AuthError, rhs: AuthError) -> Bool {
        switch (lhs, rhs) {
        case (.twoFARequired, .twoFARequired): return true
        case (.twoFACancelled, .twoFACancelled): return true
        case (.noSessionToken, .noSessionToken): return true
        case (.signinFailed(let a), .signinFailed(let b)): return a == b
        case (.twoFAFailed(let a), .twoFAFailed(let b)): return a == b
        case (.accountLoginFailed(let a), .accountLoginFailed(let b)): return a == b
        case (.invalidResponse(let a), .invalidResponse(let b)): return a == b
        default: return false
        }
    }

    case signinFailed(Int)
    case twoFARequired
    case twoFACancelled
    case twoFAFailed(Int)
    case noSessionToken
    case accountLoginFailed(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .signinFailed(let s): return "Sign in failed: HTTP \(s)"
        case .twoFARequired: return "2FA required (trust token expired)"
        case .twoFACancelled: return "2FA cancelled by user"
        case .twoFAFailed(let s): return "2FA failed: HTTP \(s)"
        case .noSessionToken: return "No session token received"
        case .accountLoginFailed(let s): return "Account login failed: HTTP \(s)"
        case .invalidResponse(let e): return "Invalid response from \(e)"
        }
    }
}
