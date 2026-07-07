import Foundation

public enum BrainErrorFileLog {
    public static let fileName = "phrover-brain-errors.log"

    public static var logFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    public static func append(error: Error, context: MissionContext, now: Date = Date()) {
        guard let url = logFileURL else { return }
        let line = format(error: error, context: context, now: now)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try line.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            AppLogger.voice.error("Brain error log write failed: \(error.localizedDescription)")
        }
    }

    static func format(error: Error, context: MissionContext, now: Date) -> String {
        let nsError = error as NSError
        let timestamp = ISO8601DateFormatter().string(from: now)
        let visible = context.visibleObjects.isEmpty
            ? "none"
            : context.visibleObjects
                .map { "\($0.label)@\(String(format: "%.2f", $0.confidence))" }
                .joined(separator: ", ")
        let openings = context.explorationCandidates.isEmpty
            ? "none"
            : context.explorationCandidates
                .map { "\($0.id)(\($0.status.rawValue))=\(String(format: "%.2f", $0.worldPoint.x)),\(String(format: "%.2f", $0.worldPoint.y))" }
                .joined(separator: ", ")
        let pose = context.pose.map {
            String(format: "x=%.2f y=%.2f yaw=%.2f", $0.position.x, $0.position.y, $0.yaw)
        } ?? "nil"

        return """
        [\(timestamp)] brain_error
        type: \(String(reflecting: Swift.type(of: error)))
        description: \(error.localizedDescription)
        domain: \(nsError.domain)
        code: \(nsError.code)
        utterance: \(context.utterance ?? "nil")
        pose: \(pose)
        navState: \(navStateDescription(context.navState))
        visibleObjects: \(visible)
        explorationCandidates: \(openings)
        plan: \(context.plan ?? "nil")
        lastAnswerWasInconclusive: \(context.lastAnswerWasInconclusive)

        """
    }

    private static func navStateDescription(_ state: NavigationController.State) -> String {
        switch state {
        case .idle: return "idle"
        case .planning: return "planning"
        case .driving: return "driving"
        case .arrived: return "arrived"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}
