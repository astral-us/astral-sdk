import Foundation

public final class RuntimeSilentSearchEventSink: SilentSearchEventSink {
    private let lock = NSLock()

    public init() {}

    public func record(event: String, fields: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        RuntimeFileLog.append(event, fields: Self.sanitized(fields))
    }

    static func sanitized(_ fields: [String: String]) -> [String: String] {
        return fields.filter { key, _ in
            let key = key.lowercased()
            return !key.contains("payload") && !key.contains("image") &&
                !["pixel_buffer", "frame_contents", "detections"].contains(key)
        }
    }
}
