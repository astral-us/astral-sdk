import Foundation

public enum PerceptionDebugSummary {
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
