import CoreGraphics
import XCTest
@testable import PhroverOperator

final class SilentSearchMapTransformTests: XCTestCase {
    func testFitUsesCommonScaleAndCentersMissionBounds() throws {
        let transform = SilentSearchMapTransform.fit(
            points: [CGPoint(x: -1, y: -2), CGPoint(x: 3, y: 2)],
            in: CGSize(width: 240, height: 120),
            padding: 10
        )

        XCTAssertEqual(transform.scale, 25, accuracy: 0.000_001)
        assertPoint(transform.canvasPoint(for: CGPoint(x: -1, y: -2)), x: 70, y: 110)
        assertPoint(transform.canvasPoint(for: CGPoint(x: 3, y: 2)), x: 170, y: 10)
    }

    func testMissionNorthMapsUpAndEastMapsRight() {
        let transform = SilentSearchMapTransform(
            missionCenter: .zero,
            canvasCenter: CGPoint(x: 50, y: 50),
            scale: 10
        )

        assertPoint(transform.canvasPoint(for: CGPoint(x: 1, y: 0)), x: 60, y: 50)
        assertPoint(transform.canvasPoint(for: CGPoint(x: 0, y: 1)), x: 50, y: 40)
    }

    func testEmptyAndDegenerateBoundsRemainFiniteAndCentered() {
        let empty = SilentSearchMapTransform.fit(points: [], in: CGSize(width: 100, height: 80), padding: 8)
        let point = SilentSearchMapTransform.fit(
            points: [CGPoint(x: 4, y: -3)], in: CGSize(width: 100, height: 80), padding: 8
        )

        XCTAssertTrue(empty.scale.isFinite)
        assertPoint(empty.canvasPoint(for: .zero), x: 50, y: 40)
        XCTAssertTrue(point.scale.isFinite)
        assertPoint(point.canvasPoint(for: CGPoint(x: 4, y: -3)), x: 50, y: 40)
    }

    private func assertPoint(_ point: CGPoint, x: CGFloat, y: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.000_001, file: file, line: line)
    }
}
