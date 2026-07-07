import Foundation
import RoverNav

/// Direct voice teleop command. These are intentionally separate from `MissionAgent`:
/// short operator phrases like "turn left" should behave like the Drive tab, not wait on
/// ARKit navigation, object grounding, or a language-model planning loop.
public struct VoiceDriveCommand: Equatable, Sendable {
    public let wheelCommand: WheelCommand
    public let durationSeconds: TimeInterval
    public let statusText: String

    public init(wheelCommand: WheelCommand, durationSeconds: TimeInterval, statusText: String) {
        self.wheelCommand = wheelCommand
        self.durationSeconds = durationSeconds
        self.statusText = statusText
    }

    public static func parse(_ utterance: String) -> VoiceDriveCommand? {
        let tokens = utterance
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let words = Set(tokens)
        let text = tokens.joined(separator: " ")
        let speed = 0.25

        if words.contains("stop") || words.contains("halt") || text.contains("emergency stop") {
            return VoiceDriveCommand(wheelCommand: .stop, durationSeconds: 0, statusText: "Stopping")
        }
        if text.contains("turn left") || text.contains("rotate left") || words == Set(["left"]) {
            return VoiceDriveCommand(wheelCommand: WheelCommand(left: -speed, right: speed),
                                     durationSeconds: 0.7,
                                     statusText: "Turning left")
        }
        if text.contains("turn right") || text.contains("rotate right") || words == Set(["right"]) {
            return VoiceDriveCommand(wheelCommand: WheelCommand(left: speed, right: -speed),
                                     durationSeconds: 0.7,
                                     statusText: "Turning right")
        }
        if text.contains("go forward") || text.contains("drive forward") || words == Set(["forward"]) {
            return VoiceDriveCommand(wheelCommand: WheelCommand(left: speed, right: speed),
                                     durationSeconds: 0.8,
                                     statusText: "Driving forward")
        }
        if text.contains("back up") ||
            text.contains("go backward") ||
            text.contains("drive backward") ||
            words.contains("reverse") ||
            words == Set(["back"]) ||
            words == Set(["backward"]) {
            return VoiceDriveCommand(wheelCommand: WheelCommand(left: -speed, right: -speed),
                                     durationSeconds: 0.8,
                                     statusText: "Backing up")
        }
        return nil
    }
}
