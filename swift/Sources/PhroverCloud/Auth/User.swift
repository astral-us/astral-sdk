import Foundation

/// Authenticated user (Cognito email/password provider).
public struct User: Codable, Sendable {
    public let id: String
    public let email: String?

    public var displayName: String { email ?? "User" }

    public init(id: String, email: String?) {
        self.id = id
        self.email = email
    }
}

public struct AuthTokens: Codable, Sendable {
    public let idToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(idToken: String, refreshToken: String?, expiresAt: Date?) {
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpiredOrExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(5 * 60) >= expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}
