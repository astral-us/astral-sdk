import XCTest
import RoverNav
@testable import PhroverKit

final class RotationCommandTests: XCTestCase {
    func testLeftRotationUsesMinimumPhysicalTurnSpeed() {
        let command = RotationCommand.command(forYawError: .pi / 2)

        XCTAssertEqual(command.left, -RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
        XCTAssertEqual(command.right, RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
    }

    func testRightRotationUsesMinimumPhysicalTurnSpeed() {
        let command = RotationCommand.command(forYawError: -.pi / 2)

        XCTAssertEqual(command.left, RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
        XCTAssertEqual(command.right, -RoverConfig.minimumRotateWheelSpeed, accuracy: 1e-9)
    }
}
