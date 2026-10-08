import Foundation

public enum PerceptionDebugSummary {
    public static func rawPredictions(_ detections: [Detector.Detection],
                                      personVerification: [PersonBodyVerifier.Decision]? = nil, limit: Int = 3) -> String {
        let ranked = detections.enumerated().sorted {
            ($0.element.confidence.isFinite ? $0.element.confidence : -.infinity) >
                ($1.element.confidence.isFinite ? $1.element.confidence : -.infinity)
        }.prefix(limit)
        guard !ranked.isEmpty else { return "none" }
        return ranked.map { index, detection in
            let accepted = verification(forDetectionAt: index, in: detections, decisions: personVerification)?.accepted ?? false
            return predictionLabel(detection, bodyVerified: accepted)
        }.joined(separator: ", ")
    }

    public static func verification(forDetectionAt index: Int, in detections: [Detector.Detection],
                                    decisions: [PersonBodyVerifier.Decision]?) -> PersonBodyVerifier.Decision? {
        guard detections.indices.contains(index), detections[index].label.lowercased() == "person" else { return nil }
        let personID = detections.prefix(index).filter { $0.label.lowercased() == "person" }.count
        return decisions?.first { $0.rawPersonID == personID }
    }

    public static func predictionLabel(_ detection: Detector.Detection, bodyVerified: Bool = false) -> String {
        let score = detection.confidence.isFinite && detection.confidence >= 0 && detection.confidence <= 1
            ? String(format: "%.4f", detection.confidence) : "unavailable"
        let check = detection.label.lowercased() == "person" ? (bodyVerified ? " (body checked)" : " (unverified)") : ""
        return "\(detection.label) score \(score)\(check)"
    }
    public static func visibleObjects(_ objects: [PerceivedObject], limit: Int = 3) -> String {
        let topObjects = objects
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)

        guard !topObjects.isEmpty else { return "none" }

        return topObjects
            .map { object in
                "\(object.label) \(Int((object.confidence * 100).rounded()))%"
            }
            .joined(separator: ", ")
    }
}
