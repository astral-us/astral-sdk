import Foundation
import RoverNav

@MainActor
public final class NavigationFollowMeMotion: FollowMeMotion {
    private let navigation: NavigationController

    public init(navigation: NavigationController) { self.navigation = navigation }

    public func rotateForScan(by angle: Double) async -> NavigationResult {
        await navigation.rotateForFollowScan(by: angle)
    }

    public func navigate(to goal: Vec2, stoppingAtForwardClearance clearance: Double) async -> NavigationResult {
        await navigation.navigateForFollow(to: goal, stoppingAtForwardClearance: clearance)
    }

    public func alignTowardPerson(by angle: Double) async -> NavigationResult {
        await navigation.rotateForFollowAlignment(by: angle)
    }

    public func stopAndConfirm() async throws { try await navigation.stopAndConfirm() }

    public func safetyStates() -> AsyncStream<NavigationSafetyState> { navigation.safetyStates() }
}
