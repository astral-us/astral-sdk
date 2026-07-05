import Foundation

/// Connection + tuning defaults for the WAVE ROVER.
public enum RoverConfig {
    /// Default host of the WAVE ROVER ESP32 web server.
    /// - AP mode (rover as its own hotspot): 192.168.4.1
    /// - STA mode (rover joined building WiFi): set to the DHCP address / Bonjour name.
    /// - e2e testing (no chassis): set E2E_ROVER_HOST to a mock ESP32's host:port.
    public static let defaultHost = ProcessInfo.processInfo.environment["E2E_ROVER_HOST"] ?? "192.168.4.1"

    /// The ESP32 firmware exposes JSON control at `GET /js?json=<url-encoded JSON>`.
    public static let jsonCommandPath = "/js"

    /// WAVE ROVER JSON command "T" opcodes we use (see Waveshare sub-controller command set).
    public enum Opcode {
        public static let speedControl = 1     // {"T":1,"L":<m/s>,"R":<m/s>}
        public static let emergencyStop = 0    // {"T":0} — stop all motors
        public static let feedbackFlowOn = 131 // continuous chassis+IMU feedback
        public static let imuQuery = 126       // one-shot IMU read
    }

    // MARK: - Physical parameters (WAVE ROVER)
    public static let wheelBase = 0.13         // m, track width (left↔right)
    public static let maxWheelSpeed = 0.5      // m/s per Waveshare closed-loop range on encoder bases; base rover is open-loop

    // MARK: - Safety
    /// If no successful command round-trip within this window, ObstacleGuard forces a stop.
    public static let commsWatchdogTimeout: TimeInterval = 0.5
    /// Drive-command resend period; keeps the base moving and doubles as a heartbeat.
    public static let commandInterval: TimeInterval = 0.1
}
