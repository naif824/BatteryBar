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

// MARK: - Credential Storage (Apple ID + password in Keychain for SRP re-auth)

final class CredentialStore {
    private static let keychain = KeychainHelper.shared

    static func save(appleID: String, password: String) {
        keychain.save(account: "appleID", password: appleID)
        keychain.save(account: "applePassword", password: password)
    }

    static func load() -> (appleID: String, password: String)? {
        guard let id = keychain.read(account: "appleID"),
              let pw = keychain.read(account: "applePassword")
        else { return nil }
        return (id, pw)
    }

    static func clear() {
        keychain.delete(account: "appleID")
        keychain.delete(account: "applePassword")
    }
}

// MARK: - Auth Token Persistence (stored in Keychain for silent re-auth)

final class AuthTokenStore {
    private static let keychain = KeychainHelper.shared

    static func save(
        sessionToken: String?,
        sessionTokenSource: String? = nil,
        trustToken: String?,
        scnt: String?,
        sessionId: String?,
        accountCountry: String? = nil,
        dsWebSessionToken: String? = nil,
        dsid: String? = nil
    ) {
        if let v = sessionToken { keychain.save(account: "sessionToken", password: v) }
        if let v = sessionTokenSource { keychain.save(account: "sessionTokenSource", password: v) }
        if let v = trustToken { keychain.save(account: "trustToken", password: v) }
        if let v = scnt { keychain.save(account: "scnt", password: v) }
        if let v = sessionId { keychain.save(account: "sessionId", password: v) }
        if let v = accountCountry { keychain.save(account: "accountCountry", password: v) }
        if let v = dsWebSessionToken { keychain.save(account: "dsWebSessionToken", password: v) }
        if let v = dsid { keychain.save(account: "dsid", password: v) }
    }

    static func load() -> (
        sessionToken: String?,
        sessionTokenSource: String?,
        trustToken: String?,
        scnt: String?,
        sessionId: String?,
        accountCountry: String?,
        dsWebSessionToken: String?,
        dsid: String?
    ) {
        return (
            keychain.read(account: "sessionToken"),
            keychain.read(account: "sessionTokenSource"),
            keychain.read(account: "trustToken"),
            keychain.read(account: "scnt"),
            keychain.read(account: "sessionId"),
            keychain.read(account: "accountCountry"),
            keychain.read(account: "dsWebSessionToken"),
            keychain.read(account: "dsid")
        )
    }

    static func clear() {
        keychain.delete(account: "sessionToken")
        keychain.delete(account: "sessionTokenSource")
        keychain.delete(account: "trustToken")
        keychain.delete(account: "scnt")
        keychain.delete(account: "sessionId")
        keychain.delete(account: "accountCountry")
        keychain.delete(account: "dsWebSessionToken")
        keychain.delete(account: "dsid")
    }
}

// MARK: - Keychain Helper

final class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "cc.naif.batterybar"

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
