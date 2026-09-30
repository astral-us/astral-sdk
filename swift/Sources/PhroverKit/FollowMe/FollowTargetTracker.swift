import Foundation
import RoverNav

/// Pure, conservative spatial association; no person identity is inferred.
public struct FollowTargetTracker {
    public let configuration: FollowMeConfiguration

    public init(configuration: FollowMeConfiguration = FollowMeConfiguration()) {
        self.configuration = configuration
    }

    public func selectInitial(_ people: [FollowPersonObservation], now: TimeInterval) -> FollowPersonObservation? {
        people.filter { eligible($0, now: now) }.min { a, b in
            let ax = a.boundingBox.midX - 0.5
            let ay = a.boundingBox.midY - 0.5
            let bx = b.boundingBox.midX - 0.5
            let by = b.boundingBox.midY - 0.5
            return ax * ax + ay * ay < bx * bx + by * by
        }
    }

    public func continueTrack(_ people: [FollowPersonObservation], previous: FollowPersonObservation,
                              predictedPosition: Vec2, now: TimeInterval) -> FollowTrackMatch {
        let matches = people.filter { candidate in
            guard eligible(candidate, now: now),
                  candidate.position.distance(to: predictedPosition) <= configuration.maximumWorldDistance else {
                return false
            }
            let dx = candidate.boundingBox.midX - previous.boundingBox.midX
            let dy = candidate.boundingBox.midY - previous.boundingBox.midY
            return boxIoU(candidate.boundingBox, previous.boundingBox) >= configuration.minimumBoxIoU ||
                hypot(dx, dy) <= configuration.maximumScreenCenterDistance
        }
        return match(matches)
    }

    public func reacquire(_ people: [FollowPersonObservation], lastPosition: Vec2,
                          now: TimeInterval) -> FollowTrackMatch {
        match(people.filter {
            eligible($0, now: now) && $0.position.distance(to: lastPosition) <= configuration.reacquisitionDistance
        })
    }

    public func standOffGoal(rover: Vec2, person: Vec2) -> Vec2? {
        let dx = person.x - rover.x
        let dy = person.y - rover.y
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance > configuration.maximumHoldDistance else { return nil }
        let travel = distance - configuration.standOffDistance
        return Vec2(rover.x + dx / distance * travel, rover.y + dy / distance * travel)
    }

    private func eligible(_ observation: FollowPersonObservation, now: TimeInterval) -> Bool {
        let box = observation.boundingBox
        let age = now - observation.timestamp
        return observation.confidence.isFinite && observation.confidence >= configuration.minimumConfidence &&
            age.isFinite && age >= 0 && age <= configuration.maximumObservationAge &&
            observation.position.x.isFinite && observation.position.y.isFinite &&
            observation.pose.position.x.isFinite && observation.pose.position.y.isFinite &&
            observation.pose.yaw.isFinite &&
            box.minX.isFinite && box.minY.isFinite && box.maxX.isFinite && box.maxY.isFinite &&
            box.width > 0 && box.height > 0
    }

    private func boxIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - intersectionArea
        return union > 0 ? intersectionArea / union : 0
    }

    private func match(_ candidates: [FollowPersonObservation]) -> FollowTrackMatch {
        switch candidates.count {
        case 0: return .lost
        case 1: return .matched(candidates[0])
        default: return .ambiguous
        }
    }
}
