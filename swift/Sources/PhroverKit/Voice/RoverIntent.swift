import FoundationModels

/// Structured command schema the on-device Apple Foundation Model fills via guided
/// generation. Kept small and enum-driven so a small on-device model can produce it
/// reliably; open-ended content (small talk, general knowledge) is deliberately NOT
/// modeled here — `needsEscalation` routes that to `DialogEscalating` instead of forcing
/// it through structured generation the on-device model isn't built for.
@Generable
public struct RoverIntent {
    @Guide(description: "What the operator wants the rover to do")
    public var action: RoverAction

    @Guide(description: "Named destination when action is navigate; empty string otherwise")
    public var destination: String

    @Guide(description: "True if this requires open-ended conversation the rover can't handle on-device: small talk, general knowledge, or anything not about moving the robot")
    public var needsEscalation: Bool
}

@Generable
public enum RoverAction: String, CaseIterable {
    case navigate
    case stop
    case greet
    case unknown
}
