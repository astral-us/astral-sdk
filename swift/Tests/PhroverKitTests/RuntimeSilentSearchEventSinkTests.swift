import XCTest
@testable import PhroverKit

final class RuntimeSilentSearchEventSinkTests: XCTestCase {
    func testSanitizerDropsFullPayloadAndImageFields() {
        XCTAssertEqual(RuntimeSilentSearchEventSink.sanitized([
            "mission": "mission-1",
            "kind": "offer",
            "payload": "complete qr",
            "qr_payload": "complete qr",
            "camera_payload": "complete qr",
            "image": "bytes",
            "pixel_buffer": "bytes",
            "frame_contents": "bytes",
        ]), [
            "mission": "mission-1",
            "kind": "offer",
        ])
    }

    func testCalibrationTelemetryAllowsOnlyDomainIdentifiersAndTypedReasons() {
        XCTAssertEqual(RuntimeSilentSearchEventSink.sanitized([
            "marker": "SILENT_SEARCH_01",
            "generation": "4",
            "frame_sequence": "12",
            "reason": "corner_unavailable",
            "corner": "top_right",
            "unvalidated_payload": "PHROVER-CAL|1|SECRET",
            "image_bytes": "bytes",
            "detections": "raw scanner output",
        ]), [
            "marker": "SILENT_SEARCH_01",
            "generation": "4",
            "frame_sequence": "12",
            "reason": "corner_unavailable",
            "corner": "top_right",
        ])
    }
}
