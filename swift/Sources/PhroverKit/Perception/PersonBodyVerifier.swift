import Foundation

/// Independent geometric evidence, not identity recognition or a guarantee
/// that a pictured body is a physical person.
public enum PersonBodyVerifier {
    public struct Joint: Sendable {
        public let location: CGPoint
        public let confidence: Float
        public init(location: CGPoint, confidence: Float) { self.location = location; self.confidence = confidence }
    }
    public struct Body: Sendable {
        public let leftShoulder: Joint?
        public let rightShoulder: Joint?
        public let leftHip: Joint?
        public let rightHip: Joint?
        public init(leftShoulder: Joint?, rightShoulder: Joint?, leftHip: Joint?, rightHip: Joint?) {
            self.leftShoulder = leftShoulder; self.rightShoulder = rightShoulder
            self.leftHip = leftHip; self.rightHip = rightHip
        }
    }
    public struct Decision: Sendable {
        public let rawPersonID: Int
        public let accepted: Bool
        public let reason: String
        public let matchingBodies: Int
        public var verificationUnavailable: Bool {
            reason == "body_verification_failed" || reason == "body_verification_unavailable"
        }
    }
    public static func verify(box: CGRect, rawPersonID: Int, bodies: [Body]) -> Decision {
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1 else {
            return .init(rawPersonID: rawPersonID, accepted: false, reason: "invalid_person_box", matchingBodies: 0)
        }
        let matching = bodies.filter { body in
            guard let leftShoulder = body.leftShoulder, let rightShoulder = body.rightShoulder,
                  let leftHip = body.leftHip, let rightHip = body.rightHip else { return false }
            let joints = [leftShoulder, rightShoulder, leftHip, rightHip]
            let bounds = box.insetBy(dx: -0.02, dy: -0.02)
            guard joints.allSatisfy({ joint in
                joint.confidence.isFinite && joint.confidence >= 0.30 && joint.confidence <= 1 &&
                    joint.location.x.isFinite && joint.location.y.isFinite &&
                    joint.location.x >= 0 && joint.location.x <= 1 && joint.location.y >= 0 && joint.location.y <= 1 &&
                    joint.location.x >= bounds.minX && joint.location.x <= bounds.maxX &&
                    joint.location.y >= bounds.minY && joint.location.y <= bounds.maxY
            }) else { return false }
            return abs(leftShoulder.location.x - rightShoulder.location.x) >= 0.02 &&
                abs(leftHip.location.x - rightHip.location.x) >= 0.02 &&
                (leftShoulder.location.y + rightShoulder.location.y) / 2 -
                    (leftHip.location.y + rightHip.location.y) / 2 >= 0.05
        }.count
        return .init(rawPersonID: rawPersonID, accepted: matching == 1,
            reason: matching == 1 ? "body_verified" : (matching == 0 ? "no_matching_body" : "ambiguous_body"),
            matchingBodies: matching)
    }
}
