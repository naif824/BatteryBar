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
