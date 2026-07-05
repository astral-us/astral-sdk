import Foundation

/// Chassis + IMU feedback streamed by the WAVE ROVER ESP32 (feedback flow, T≈1001).
/// Fields mirror the Waveshare sub-controller feedback frame; all optional since the
/// exact set varies by firmware/base.
public struct RoverFeedback: Codable, Sendable {
    public let T: Int?
    public let L: Double?     // left wheel speed (m/s)
    public let R: Double?     // right wheel speed (m/s)
    public let ax: Double?    // accel
    public let ay: Double?
    public let az: Double?
    public let gx: Double?    // gyro
    public let gy: Double?
    public let gz: Double?
    public let roll: Double?
    public let pitch: Double?
    public let yaw: Double?
    public let v: Double?     // bus voltage

    enum CodingKeys: String, CodingKey {
        case T, L, R, ax, ay, az, gx, gy, gz, v
        case roll = "r", pitch = "p", yaw = "y"
    }
}

public extension RoverFeedback {
    /// Parse one newline-delimited JSON feedback frame; returns nil on malformed input.
    static func parse(_ line: String) -> RoverFeedback? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RoverFeedback.self, from: data)
    }

    /// Rough tip-over guard input: true if pitch/roll magnitude exceeds a threshold (rad).
    func isTipping(threshold: Double = 0.6) -> Bool {
        (abs(roll ?? 0) > threshold) || (abs(pitch ?? 0) > threshold)
    }
}
