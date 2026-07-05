import Foundation

/// Minimal HTTP client for the reference `eco/aws` API Gateway — trimmed to the one call
/// `MQTTService` needs (attach the Cognito identity's IoT policy before connecting).
public actor APIClient {
    private let baseURL: URL

    public init(config: PhroverCloudConfig) {
        guard let url = URL(string: config.apiEndpoint) else {
            fatalError("Invalid API endpoint URL in PhroverCloudConfig: \(config.apiEndpoint)")
        }
        self.baseURL = url
    }

    private struct AttachIoTPolicyRequest: Encodable { let identityId: String }
    private struct AttachIoTPolicyResponse: Decodable {}

    /// Attach this Cognito identity to the backend's shared IoT policy — required once per
    /// identity before it can publish/subscribe over MQTT.
    public func attachIoTPolicy(identityId: String, idToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/iot-policy"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AttachIoTPolicyRequest(identityId: identityId))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIClientError.serverError
        }
        _ = try? JSONDecoder().decode(AttachIoTPolicyResponse.self, from: data)
    }
}

public enum APIClientError: LocalizedError {
    case serverError
    public var errorDescription: String? { "Failed to attach IoT policy." }
}
