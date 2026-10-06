import Foundation
import RoverNav

public enum RoverCommandLinkReadiness: Equatable, Sendable {
    case available
    case unavailable
}

/// Low-level driver for the WAVE ROVER ESP32 over WiFi HTTP.
///
/// Speaks the Waveshare JSON command protocol: commands are sent as
/// `GET /js?json={"T":1,"L":<left>,"R":<right>}`. Left/right are wheel linear velocities (m/s).
public actor RoverControl {
    private let baseURL: URL
    private let session: URLSession
    private let retrySleep: @Sendable (TimeInterval) async -> Void

    /// Timestamp of the last successful command; the comms watchdog reads this.
    public private(set) var lastAckAt: Date?

    public init(host: String = RoverConfig.defaultHost, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://\(host)")!
        self.session = session
        self.retrySleep = { try? await Task.sleep(for: .seconds($0)) }
    }

    init(host: String = RoverConfig.defaultHost, session: URLSession,
         retrySleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.baseURL = URL(string: "http://\(host)")!
        self.session = session
        self.retrySleep = retrySleep
    }

    // MARK: - Motion

    func sendNavigationWithReceipt(_ cmd: WheelCommand) async -> RoverCommandDiagnosticResult {
        await sendJSONDiagnostic(["T": RoverConfig.Opcode.speedControl, "L": cmd.right, "R": cmd.left],
            authorization: cmd.left != 0 || cmd.right != 0 ? FollowTurnBurstTransportScope.authorization : nil)
    }

    func sendNavigationWithReceipt(_ cmd: WheelCommand,
                                   authorization: FollowTurnBurstAuthorization) async -> RoverCommandDiagnosticResult {
        await sendJSONDiagnostic(["T": RoverConfig.Opcode.speedControl, "L": cmd.right, "R": cmd.left],
            authorization: cmd.left != 0 || cmd.right != 0 ? authorization : nil)
    }

    func stopWithReceipt() async -> RoverCommandDiagnosticResult {
        await sendJSONDiagnostic(["T": RoverConfig.Opcode.emergencyStop])
    }

    /// Stream a differential-drive command. The single source of motion for autonomy.
    public func send(_ cmd: WheelCommand) async throws {
        try await sendJSON(["T": RoverConfig.Opcode.speedControl,
                            "L": cmd.left,
                            "R": cmd.right])
    }

    /// Send a navigation command after converting RoverNav yaw to the mounted
    /// WAVE ROVER's physical turn direction. Manual drive commands use `send(_:)`.
    public func sendNavigation(_ cmd: WheelCommand) async throws {
        // RoverNav uses mathematical CCW-positive yaw. ARKit's x/world-z ground plane
        // reports the opposite physical turn sign, so swap wheel channels only at the
        // WAVE ROVER boundary. Forward/reverse commands are unchanged by the swap.
        _ = try await sendNavigationWithReceipt(cmd).get()
    }

    /// Hard stop. Safe to call repeatedly; used by e-stop and the watchdog.
    public func stop() async throws {
        _ = try await stopWithReceipt().get()
    }

    /// Ask the base to stream continuous chassis + IMU feedback (parsed by `RoverFeedback`).
    public func enableFeedbackFlow() async throws {
        try await sendJSON(["T": RoverConfig.Opcode.feedbackFlowOn, "cmd": 1])
    }

    /// Verify the command link without issuing a wheel-motion opcode.
    public func probeLink() async throws {
        try await sendJSON(["T": RoverConfig.Opcode.feedbackFlowOn, "cmd": 1])
    }

    public func commandLinkReadiness() -> AsyncStream<RoverCommandLinkReadiness> {
        AsyncStream { continuation in
            let task = Task {
                var previous: RoverCommandLinkReadiness?
                while !Task.isCancelled {
                    let readiness: RoverCommandLinkReadiness
                    do {
                        try await probeLink()
                        readiness = .available
                    } catch {
                        readiness = .unavailable
                    }
                    if readiness != previous, readiness == .available || previous != nil {
                        continuation.yield(readiness)
                    }
                    previous = readiness
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Transport

    private func sendJSON(_ payload: [String: Any]) async throws {
        _ = try await sendJSONDiagnostic(payload).get()
    }

    private func sendJSONDiagnostic(_ payload: [String: Any],
                                    authorization: FollowTurnBurstAuthorization? = nil) async -> RoverCommandDiagnosticResult {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) }
        catch { return .init(receipt: .unknown, failure: error) }
        guard let json = String(data: data, encoding: .utf8) else {
            return .init(receipt: .unknown, failure: RoverControlError.encodingFailed)
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent(RoverConfig.jsonCommandPath),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "json", value: json)]
        guard let url = comps.url else { return .init(receipt: .unknown, failure: RoverControlError.encodingFailed) }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = RoverConfig.commsWatchdogTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let attempts = max(1, RoverConfig.commandRetryAttempts)
        var lastError: Error?
        var lastStatusCode: Int?

        for attempt in 1...attempts {
            if let authorization {
                let attemptAuthorized = await authorization.authorizeAttempt?() ?? true
                // No suspension between these final gates and creation of the HTTP task.
                if Task.isCancelled {
                    return .init(receipt: .init(httpStatus: lastStatusCode, acknowledged: false,
                        acknowledgementUTC: nil, attempts: attempt - 1, outcome: "cancelled"),
                        failure: FollowTurnBurstTransportDenial.cancelled)
                }
                let time = authorization.uptime()
                if !time.isFinite || !authorization.deadline.isFinite || time >= authorization.deadline {
                    return .init(receipt: .init(httpStatus: lastStatusCode, acknowledged: false,
                        acknowledgementUTC: nil, attempts: attempt - 1, outcome: "expired"),
                        failure: FollowTurnBurstTransportDenial.expired)
                }
                if !attemptAuthorized || !authorization.isAuthorized() {
                    return .init(receipt: .init(httpStatus: lastStatusCode, acknowledged: false,
                        acknowledgementUTC: nil, attempts: attempt - 1, outcome: "fenced"),
                        failure: FollowTurnBurstTransportDenial.fenced)
                }
                authorization.didEnterAttempt?(.init(operationID: authorization.operationID,
                    attempt: attempt, entryUptime: time))
            }
            var didLogResponse = false
            var statusCode: Int?
            do {
                let (_, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    RuntimeFileLog.append("rover_command_request", fields: Self.requestLogFields(url: url,
                                                                                                  attempt: attempt,
                                                                                                  maxAttempts: attempts,
                                                                                                  statusCode: nil,
                                                                                                  error: RoverControlError.invalidResponse))
                    didLogResponse = true
                    throw RoverControlError.invalidResponse
                }
                RuntimeFileLog.append("rover_command_request", fields: Self.requestLogFields(url: url,
                                                                                              attempt: attempt,
                                                                                              maxAttempts: attempts,
                                                                                              statusCode: http.statusCode,
                                                                                              error: nil))
                didLogResponse = true
                statusCode = http.statusCode
                lastStatusCode = http.statusCode
                guard (200...299).contains(http.statusCode) else {
                    throw RoverControlError.serverError(http.statusCode)
                }
                lastAckAt = Date()
                return .init(receipt: .init(httpStatus: http.statusCode, acknowledged: true,
                    acknowledgementUTC: lastAckAt, attempts: attempt, outcome: "acknowledged"), failure: nil)
            } catch {
                lastError = error
                if !didLogResponse {
                    RuntimeFileLog.append("rover_command_request", fields: Self.requestLogFields(url: url,
                                                                                                  attempt: attempt,
                                                                                                  maxAttempts: attempts,
                                                                                                  statusCode: nil,
                                                                                                  error: error))
                }
                guard attempt < attempts, Self.isRetryableTransportError(error) else {
                    let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                    return .init(receipt: .init(httpStatus: statusCode, acknowledged: false,
                        acknowledgementUTC: nil, attempts: attempt,
                        outcome: cancelled ? "cancelled" : "failed"), failure: error)
                }

                if let authorization {
                    let time = authorization.uptime()
                    let denial: FollowTurnBurstTransportDenial?
                    let outcome: String
                    if Task.isCancelled { denial = .cancelled; outcome = "cancelled" }
                    else if !time.isFinite || !authorization.deadline.isFinite || time >= authorization.deadline {
                        denial = .expired; outcome = "expired"
                    } else if !authorization.isAuthorized() { denial = .fenced; outcome = "fenced" }
                    else { denial = nil; outcome = "unknown" }
                    if let denial {
                        return .init(receipt: .init(httpStatus: statusCode, acknowledged: false,
                            acknowledgementUTC: nil, attempts: attempt, outcome: outcome), failure: denial)
                    }
                }

                RuntimeFileLog.append("rover_command_retry", fields: [
                    "attempt": "\(attempt)",
                    "max": "\(attempts)",
                    "error": error.localizedDescription
                ])
                await retrySleep(RoverConfig.commandRetryBackoff)
            }
        }

        return .init(receipt: .unknown, failure: lastError ?? RoverControlError.invalidResponse)
    }

    static func requestLogFields(url: URL,
                                 attempt: Int,
                                 maxAttempts: Int,
                                 statusCode: Int?,
                                 error: Error?) -> [String: String] {
        var fields: [String: String] = [
            "url": url.absoluteString,
            "attempt": "\(attempt)",
            "max": "\(maxAttempts)"
        ]
        if let statusCode {
            fields["status"] = "\(statusCode)"
        } else if error != nil {
            fields["status"] = "transport_error"
        } else {
            fields["status"] = "unknown"
        }
        if let error {
            fields["error"] = error.localizedDescription
        }
        return fields
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
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
