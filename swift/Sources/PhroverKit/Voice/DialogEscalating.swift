import Foundation

/// Cloud conversation fallback, invoked by `DialogAgent` only when the on-device model
/// escalates (open-ended chat, general knowledge, or a failed parse). PhroverKit only
/// depends on this protocol so it never has to import a cloud SDK — `PhroverCloud` ships
/// a concrete conformer (`ClaudeDialogClient`), or bring your own backend.
public protocol DialogEscalating: Sendable {
    func converse(_ utterance: String) async throws -> String
}

/// Default used when no cloud escalation is configured — on-device-only operation degrades
/// gracefully instead of crashing or silently ignoring open-ended requests.
public struct NoDialogEscalation: DialogEscalating {
    public init() {}

    public func converse(_ utterance: String) async throws -> String {
        throw DialogEscalationError.notConfigured
    }
}

public enum DialogEscalationError: LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        "No cloud dialog escalation configured — pass a DialogEscalating conformer to DialogAgent."
    }
}
