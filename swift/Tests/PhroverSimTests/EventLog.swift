import Foundation

/// Every mission-side event (brain decisions, speech, asks) as a single `EVT {json}`
/// stdout line, plus an in-memory copy `CapstoneTests` reads directly (no need to
/// round-trip through this process's own stdout for in-process assertions). The
/// Python harness (eco/rover/sim/depot_harness.py) is the one that needs the stdout
/// line — `xcodebuild test` output is the reliable channel from an iOS Simulator test
/// process; `EVENTS_OUT` (if set) also gets a best-effort JSONL file.
final class EventLog: @unchecked Sendable {
    struct Event {
        let t: Double
        let kind: String
        let data: [String: Any]
    }

    private let startTime = Date()
    private let fileHandle: FileHandle?
    private let lock = NSLock()
    private var _events: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    init() {
        if let path = ProcessInfo.processInfo.environment["EVENTS_OUT"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: path)
        } else {
            fileHandle = nil
        }
    }

    func log(_ kind: String, _ data: [String: Any] = [:]) {
        lock.lock()
        let t = Date().timeIntervalSince(startTime)
        _events.append(Event(t: t, kind: kind, data: data))
        lock.unlock()

        let obj: [String: Any] = ["t": t, "kind": kind, "data": data]
        guard JSONSerialization.isValidJSONObject(obj),
              let payload = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: payload, encoding: .utf8)
        else { return }
        print("EVT \(line)")
        if let fh = fileHandle, let lineData = (line + "\n").data(using: .utf8) {
            fh.write(lineData)
        }
    }
}
