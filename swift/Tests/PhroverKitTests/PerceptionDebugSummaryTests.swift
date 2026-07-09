import XCTest
import CoreGraphics
@testable import PhroverKit

final class PerceptionDebugSummaryTests: XCTestCase {
    func testVisibleObjectSummaryShowsTopLabelsAndConfidence() {
        let objects = [
            PerceivedObject(label: "chair", confidence: 0.752, normalizedPoint: CGPoint(x: 0.1, y: 0.2)),
            PerceivedObject(label: "table", confidence: 0.934, normalizedPoint: CGPoint(x: 0.3, y: 0.4)),
            PerceivedObject(label: "person", confidence: 0.611, normalizedPoint: CGPoint(x: 0.5, y: 0.6)),
        ]

        XCTAssertEqual(PerceptionDebugSummary.visibleObjects(objects), "table 93%, chair 75%, person 61%")
    }

    func testVisibleObjectSummaryReportsNoneWhenEmpty() {
        XCTAssertEqual(PerceptionDebugSummary.visibleObjects([]), "none")
    }
}
