import XCTest
@testable import PhroverKit

final class OfflineObjectMissionIntentParserTests: XCTestCase {
    func testParsesVisibleObjectWithoutImplicitReturn() throws {
        let intent = try XCTUnwrap(OfflineObjectMissionIntentParser.parse("Go to the fridge"))
        XCTAssertEqual(intent.objectQuery, "refrigerator")
        XCTAssertEqual(intent.targetLabel, "refrigerator")
        XCTAssertEqual(intent.requestedColors, [])
        XCTAssertFalse(intent.searchOtherRooms)
        XCTAssertFalse(intent.shouldReturn)
    }

    func testParsesColorOtherRoomAndExplicitReturn() throws {
        let intent = try XCTUnwrap(OfflineObjectMissionIntentParser.parse(
            "Go to the black chair in the other room and come back"
        ))
        XCTAssertEqual(intent.objectQuery, "black chair")
        XCTAssertEqual(intent.targetLabel, "chair")
        XCTAssertEqual(intent.requestedColors, [.black])
        XCTAssertTrue(intent.searchOtherRooms)
        XCTAssertTrue(intent.shouldReturn)
    }

    func testRejectsCommandsOutsideObjectNavigationContract() {
        XCTAssertNil(OfflineObjectMissionIntentParser.parse("Tell me a joke"))
        XCTAssertNil(OfflineObjectMissionIntentParser.parse("Go to the chair and bring me a book"))
        XCTAssertNil(OfflineObjectMissionIntentParser.parse("Go to"))
    }
}
