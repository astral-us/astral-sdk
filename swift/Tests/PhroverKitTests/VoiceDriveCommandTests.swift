import XCTest
import RoverNav
@testable import PhroverKit

final class VoiceDriveCommandTests: XCTestCase {
    func testTurnLeftMapsToManualDriveLeftCommand() {
        let command = VoiceDriveCommand.parse("Turn left")

        XCTAssertEqual(command?.wheelCommand, WheelCommand(left: -0.25, right: 0.25))
    }

    func testNonTeleopPhraseFallsThroughToMissionAgent() {
        XCTAssertNil(VoiceDriveCommand.parse("go find the chair"))
        XCTAssertNil(VoiceDriveCommand.parse("go back to the chair"))
    }
}
