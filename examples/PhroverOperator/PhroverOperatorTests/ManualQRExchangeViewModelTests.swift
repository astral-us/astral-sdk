import XCTest
@testable import PhroverOperator

@MainActor
final class ManualQRExchangeViewModelTests: XCTestCase {
    func testScriptedManualExchangeProjectsOneActionAtATime() {
        let generate = ScriptedSilentSearchViewModel(scenario: .generateOffer)
        XCTAssertEqual(generate.phase, .pendingGenerateQR)
        XCTAssertEqual(generate.opticalMessageLabel, "Offer")
        XCTAssertNil(generate.qrImage)

        generate.generateQR()
        XCTAssertEqual(generate.phase, .displayingQR)
        XCTAssertEqual(generate.presentationSecondsRemaining, 10)

        generate.completeQRPresentation()
        XCTAssertEqual(generate.phase, .pendingScanQR)
        generate.beginQRScan()
        XCTAssertEqual(generate.phase, .scanning)
        XCTAssertNotNil(generate.scanPreviewImage)
        generate.cancelQRScan()
        XCTAssertEqual(generate.phase, .pendingScanQR)
    }

    func testScanTimeoutReturnsToPendingScanWithGuidance() {
        let model = ScriptedSilentSearchViewModel(scenario: .scanTimeout)

        XCTAssertEqual(model.phase, .pendingScanQR)
        XCTAssertTrue(model.detail.contains("Try again"))
        XCTAssertNil(model.qrImage)
    }
}
