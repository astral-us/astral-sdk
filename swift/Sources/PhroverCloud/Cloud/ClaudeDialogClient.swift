import Foundation
import PhroverKit

/// Cloud conversational fallback for pure text dialog. Talks to the reference `eco/aws`
/// `/rover/converse` route, which forwards to an LLM — conforms to `DialogEscalating` so
/// any `DialogEscalating`-consuming caller can use it. (`MissionAgent`'s action loop uses
/// `RoverBrain`/`CloudBrain` instead — this client is for plain conversation, not actions.)
public actor ClaudeDialogClient: DialogEscalating {
    private let baseURL: URL
    private let session: URLSession = .shared

    // Async because the real token provider (AuthService) is @MainActor-isolated; a
    // synchronous closure couldn't read its idToken from this actor's executor.
    private var tokenProvider: (@Sendable () async -> String?)?

    public init(config: PhroverCloudConfig) {
        self.baseURL = URL(string: config.apiEndpoint)!
    }

    public func setTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        tokenProvider = provider
    }

    private struct ConverseRequest: Codable { let utterance: String }
    private struct ConverseResponse: Codable { let reply: String }

    public func converse(_ utterance: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("rover/converse"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider?() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(ConverseRequest(utterance: utterance))

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ClaudeDialogError.serverError
        }
        return try JSONDecoder().decode(ConverseResponse.self, from: data).reply
    }
}

public enum ClaudeDialogError: LocalizedError {
    case serverError
    public var errorDescription: String? { "Cloud conversation service unavailable." }
}
