import Foundation
import RoverNav

enum RotationCommand {
    static let gain = 2.0
    static let maxAngular = 1.5

    static func command(forYawError error: Double) -> WheelCommand {
        let w = min(max(error * gain, -maxAngular), maxAngular)
        var command = DifferentialDrive.wheels(v: 0,
                                               w: w,
                                               wheelBase: RoverConfig.wheelBase,
                                               maxWheelSpeed: RoverConfig.maxWheelSpeed)
        let peak = max(abs(command.left), abs(command.right))
        guard peak > 0, peak < RoverConfig.minimumRotateWheelSpeed else { return command }

        let scale = RoverConfig.minimumRotateWheelSpeed / peak
        command.left *= scale
        command.right *= scale
        return command
    }
}
