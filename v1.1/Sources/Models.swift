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
    let batteryLevel: Int?       // 0-100, available for both online and offline devices
    let isCharging: Bool
    let lowPowerMode: Bool
    let isReachable: Bool        // deviceStatus == "200"
    let lastSeenTimestamp: Date? // from location.timeStamp (epoch ms)
}

struct AppConfig: Codable {
    var appleID: String?
    var refreshInterval: TimeInterval = 300
    var hiddenDeviceIDs: [String] = []
}
