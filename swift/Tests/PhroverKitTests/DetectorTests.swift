import XCTest
import ImageIO
import CoreML
@testable import PhroverKit

final class DetectorTests: XCTestCase {
    func testModelResourcePrefersCompiledModelBundle() {
        let url = Detector.modelResourceURL(modelName: "RoverYOLO")

        XCTAssertEqual(url?.pathExtension, "mlmodelc")
    }

    func testFallbackOrientationsTryPreferredFirstAndDeduplicate() {
        XCTAssertEqual(Detector.detectionOrientations(preferred: .right), [.right, .up, .left, .down])
        XCTAssertEqual(Detector.detectionOrientations(preferred: .up), [.up, .right, .left, .down])
    }

    func testModelConfigurationAvoidsGPUForBackgroundSafety() {
        XCTAssertEqual(Detector.modelConfiguration().computeUnits, .cpuAndNeuralEngine)
    }
}
