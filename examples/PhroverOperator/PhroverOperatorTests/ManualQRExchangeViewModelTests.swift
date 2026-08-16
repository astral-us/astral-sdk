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

    func testValidationFailureAndTrackingSuspensionShowActionableGuidance() {
        let invalid = ScriptedSilentSearchViewModel(scenario: .scanInvalidPayload)
        XCTAssertEqual(invalid.phase, .pendingScanQR)
        XCTAssertEqual(invalid.detail, "QR payload is invalid. Scan the expected QR.")

        let suspended = ScriptedSilentSearchViewModel(scenario: .scanTrackingSuspended)
        XCTAssertEqual(suspended.phase, .trackingSuspended)
        XCTAssertEqual(suspended.detail, "Tracking is limited. Hold still until normal tracking returns.")
        XCTAssertNil(suspended.scanPreviewImage)
    }

    func testLiveProjectionPrioritizesTrackingSuspensionAndMapsValidationGuidance() {
        XCTAssertEqual(
            LiveSilentSearchViewModel.operatorPhase(
                coordinatorPhase: .handshake(.scanning),
                pendingAction: nil,
                trackingSuspended: true
            ),
            .trackingSuspended
        )
        XCTAssertEqual(
            LiveSilentSearchViewModel.validationMessage(.wrongMarker),
            "QR uses another marker. Scan the expected QR."
        )
    }
}
