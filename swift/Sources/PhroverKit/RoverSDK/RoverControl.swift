import Foundation
import RoverNav

/// Low-level driver for the WAVE ROVER ESP32 over WiFi HTTP.
///
/// Speaks the Waveshare JSON command protocol: commands are sent as
/// `GET /js?json={"T":1,"L":<left>,"R":<right>}`. Left/right are wheel linear velocities (m/s).
public actor RoverControl {
    private let baseURL: URL
    private let session: URLSession

    /// Timestamp of the last successful command; the comms watchdog reads this.
    public private(set) var lastAckAt: Date?

    public init(host: String = RoverConfig.defaultHost, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://\(host)")!
        self.session = session
    }

    // MARK: - Motion

    /// Stream a differential-drive command. The single source of motion for autonomy.
    public func send(_ cmd: WheelCommand) async throws {
        try await sendJSON(["T": RoverConfig.Opcode.speedControl,
                            "L": cmd.left,
                            "R": cmd.right])
    }

    /// Hard stop. Safe to call repeatedly; used by e-stop and the watchdog.
    public func stop() async throws {
        try await sendJSON(["T": RoverConfig.Opcode.emergencyStop])
    }

    /// Ask the base to stream continuous chassis + IMU feedback (parsed by `RoverFeedback`).
    public func enableFeedbackFlow() async throws {
        try await sendJSON(["T": RoverConfig.Opcode.feedbackFlowOn, "cmd": 1])
    }

    // MARK: - Transport

    private func sendJSON(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw RoverControlError.encodingFailed
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent(RoverConfig.jsonCommandPath),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "json", value: json)]
        guard let url = comps.url else { throw RoverControlError.encodingFailed }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = RoverConfig.commsWatchdogTimeout

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RoverControlError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw RoverControlError.serverError(http.statusCode)
        }
        lastAckAt = Date()
    }
}

public enum RoverControlError: LocalizedError {
    case encodingFailed
    case invalidResponse
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode rover command."
        case .invalidResponse: return "Invalid response from rover."
        case .serverError(let code): return "Rover returned error \(code)."
        }
    }
}
