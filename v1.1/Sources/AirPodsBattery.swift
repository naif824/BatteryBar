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
