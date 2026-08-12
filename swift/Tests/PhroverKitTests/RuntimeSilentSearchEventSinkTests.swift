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
}
