import Foundation

enum DebugLog {
    private static let appSupportFolder = "BatteryBarV7"
    private static let mirroredLogFiles = ["debug.log"]
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String, category: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appSupportFolder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for filename in mirroredLogFiles {
            append(data: data, to: dir.appendingPathComponent(filename))
        }
    }

    static func tokenSummary(_ token: String?) -> String {
        guard let token, !token.isEmpty else { return "nil" }
        let prefix = String(token.prefix(8))
        return "len=\(token.count),prefix=\(prefix)"
    }

    static func presence(_ value: String?) -> String {
        value == nil ? "no" : "yes"
    }

    private static func append(data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
