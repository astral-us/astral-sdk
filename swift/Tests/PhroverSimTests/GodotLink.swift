import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Blocking newline-JSON TCP client to the Godot Depot sim's IPC server
/// (eco/drone/sim/godot/scripts/ipc_server.gd + phrover_manager.gd).
///
/// Synchronous by design: `RoverPerception`'s protocol methods (`pose`, `detectObjects()`,
/// `unproject`, `explorationFrontiers()`) are not `async`, so calls into Godot made from
/// inside them must block — exactly like the real ARKit calls they replace in the sim.
/// A serial lock (not actor isolation) guards the socket so it's safe to share one
/// `GodotLink` across GodotMotion's background drive Task and GodotPerception's
/// MainActor-synchronous calls.
final class GodotLink: @unchecked Sendable {
    enum LinkError: Error { case socketFailed, connectFailed }

    private let fd: Int32
    private let lock = NSLock()

    init(host: String? = nil, port: UInt16? = nil) throws {
        let env = ProcessInfo.processInfo.environment
        let resolvedHost = host ?? env["GODOT_HOST"] ?? "127.0.0.1"
        let resolvedPort = port ?? UInt16(env["GODOT_PORT"] ?? "") ?? 9999

        // Godot prints "IPC ready" (which godot_launcher.py's launch_depot() blocks on)
        // as soon as its listen socket is up, but that doesn't guarantee this process's
        // very first connect() lands in the accept backlog instantly — confirmed live: a
        // multi-beat run_live_beats.py session had one beat's connection refused in 0.004s
        // (an immediate ECONNREFUSED, not a hang) right after a fresh Godot relaunch, while
        // the frame-grabber's separate connection to the same port succeeded around the
        // same time. A single one-shot connect() attempt is too fragile against that
        // startup race; retry with a short backoff before giving up for real.
        var lastResult: Int32 = -1
        var sock: Int32 = -1
        for attempt in 0..<20 {
            sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { throw LinkError.socketFailed }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_port = resolvedPort.bigEndian
            addr.sin_addr.s_addr = inet_addr(resolvedHost)

            lastResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if lastResult == 0 { break }
            close(sock)
            sock = -1
            if attempt < 19 { usleep(300_000) }  // 300ms
        }
        guard lastResult == 0, sock >= 0 else {
            throw LinkError.connectFailed
        }
        self.fd = sock
    }

    deinit { close(fd) }

    /// Send one newline-JSON request, block for one newline-JSON response line.
    @discardableResult
    func call(_ req: [String: Any]) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        guard var payload = try? JSONSerialization.data(withJSONObject: req) else {
            return ["ok": false, "error": "request encode failed"]
        }
        payload.append(0x0A)
        let sent: Bool = payload.withUnsafeBytes { raw in
            guard var p = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                guard n > 0 else { return false }
                p += n
                remaining -= n
            }
            return true
        }
        guard sent else { return ["ok": false, "error": "write failed"] }

        var line = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            guard n == 1 else { break }
            if byte == 0x0A { break }
            line.append(byte)
        }
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return ["ok": false, "error": "no/bad response"] }
        return obj
    }
}

// MARK: - Loose-typing helpers (JSONSerialization boxes numbers as NSNumber)

func godotDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

func godotInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

func godotDoubleArray(_ v: Any?) -> [Double]? {
    guard let arr = v as? [Any] else { return nil }
    let out = arr.compactMap { godotDouble($0) }
    return out.count == arr.count ? out : nil
}
