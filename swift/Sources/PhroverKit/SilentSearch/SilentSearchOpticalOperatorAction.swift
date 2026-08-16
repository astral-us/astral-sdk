public enum SilentSearchOpticalOperatorAction: Equatable, Sendable {
    case generate(messageKind: OpticalMessageKind, isRetransmission: Bool)
    case scan(expectedMessageKind: OpticalMessageKind)
}
