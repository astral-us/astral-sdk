import Foundation

public enum RuntimeFileLog {
    public static let fileName = "phrover-runtime.log"

    public static var logFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    public static func append(_ event: String, fields: [String: String] = [:], now: Date = Date()) {
        guard let url = logFileURL else { return }
        let line = format(event, fields: fields, now: now)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try line.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            AppLogger.nav.error("Runtime log write failed: \(error.localizedDescription)")
        }
    }

    static func format(_ event: String, fields: [String: String], now: Date) -> String {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let detail = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        if detail.isEmpty {
            return "[\(timestamp)] \(event)\n"
        }
        return "[\(timestamp)] \(event) \(detail)\n"
    }
}
