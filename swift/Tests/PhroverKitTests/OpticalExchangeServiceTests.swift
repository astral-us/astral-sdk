import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import RoverNav
import XCTest
@testable import PhroverKit

final class OpticalExchangeServiceTests: XCTestCase {
    func testGeneratedQRRoundTripsCanonicalGoldenAndLargestPayloads() throws {
        let codec = OpticalMessageCodec()
        let payloads = try (goldenMessages() + [largestStatus(), largestDecision()]).map(codec.encode)
        let renderer = OpticalQRCodeRenderer()
        let scanner = OpticalQRCodeScanner()

        for (index, payload) in payloads.enumerated() {
            let image = try renderer.render(payload: payload, moduleScale: 8)
            let observations = try scanner.scan(OpticalFrame(
                image: image, frameID: UInt64(index + 1), monotonicTimestamp: Double(index)
            ))
            XCTAssertEqual(observations.map(\.payload), [payload])
            XCTAssertEqual(observations.first?.frameID, UInt64(index + 1))
            XCTAssertEqual(observations.first?.monotonicTimestamp, Double(index))
        }
    }

    func testRendererAddsFourModuleQuietZoneAndOnlyHardBlackWhitePixels() throws {
        let scale = 7
        let image = try OpticalQRCodeRenderer().render(
            payload: try OpticalMessageCodec().encode(goldenOffer()), moduleScale: scale
        )
        let pixels = try rgbaPixels(image)
        let quietPixels = 4 * scale

        XCTAssertTrue((0..<image.width).allSatisfy { x in
            (0..<quietPixels).allSatisfy { y in pixel(pixels, width: image.width, x: x, y: y) == [255, 255, 255, 255] }
        })
        let hasOnlyHardPixels = pixels.enumerated().allSatisfy { index, value in
            index % 4 == 3 ? value == 255 : value == 0 || value == 255
        }
        XCTAssertTrue(hasOnlyHardPixels)
        XCTAssertTrue(pixels.contains(0))
    }

    func testScannerSuppressesRepeatedFrameAndReturnsNormalizedOrientedCorners() throws {
        let image = try OpticalQRCodeRenderer().render(
            payload: try OpticalMessageCodec().encode(goldenOffer()), moduleScale: 8
        )
        let scanner = OpticalQRCodeScanner()
        let frame = OpticalFrame(image: image, frameID: 42, monotonicTimestamp: 12.5)

        let first = try XCTUnwrap(scanner.scan(frame).first)
        XCTAssertTrue([first.corners.topLeft, first.corners.topRight,
                       first.corners.bottomLeft, first.corners.bottomRight].allSatisfy {
            (0...1).contains($0.x) && (0...1).contains($0.y)
        })
        XCTAssertGreaterThan(first.corners.topLeft.y, first.corners.bottomLeft.y)
        XCTAssertEqual(try scanner.scan(frame), [])
    }

    func testScannerCanonicalizesCornersFromEveryFallbackOrientation() {
        let expected = OrientedMarkerCorners(
            topLeft: Vec2(0.1, 0.9), topRight: Vec2(0.7, 0.8),
            bottomLeft: Vec2(0.2, 0.3), bottomRight: Vec2(0.8, 0.2)
        )
        let workedExamples: [(CGImagePropertyOrientation, OrientedMarkerCorners)] = [
            (.right, expected),
            (.up, OrientedMarkerCorners(
                topLeft: Vec2(0.2, 0.7), topRight: Vec2(0.8, 0.8),
                bottomLeft: Vec2(0.1, 0.1), bottomRight: Vec2(0.7, 0.2)
            )),
            (.left, OrientedMarkerCorners(
                topLeft: Vec2(0.2, 0.8), topRight: Vec2(0.8, 0.7),
                bottomLeft: Vec2(0.3, 0.2), bottomRight: Vec2(0.9, 0.1)
            )),
            (.down, OrientedMarkerCorners(
                topLeft: Vec2(0.3, 0.8), topRight: Vec2(0.9, 0.9),
                bottomLeft: Vec2(0.2, 0.2), bottomRight: Vec2(0.8, 0.3)
            )),
        ]

        for (orientation, corners) in workedExamples {
            assertCorners(
                OpticalObservation.canonicalizedCorners(corners, from: orientation),
                equalTo: expected,
                orientation: orientation
            )
        }
    }

    func testScannerIgnoresBlankAndNonQRImages() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let blankImage = try XCTUnwrap(context.createCGImage(blank, from: blank.extent))
        let code128 = CIFilter.code128BarcodeGenerator()
        code128.message = Data("not-a-qr".utf8)
        let barcode = code128.outputImage!.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let barcodeImage = try XCTUnwrap(context.createCGImage(barcode, from: barcode.extent))
        let scanner = OpticalQRCodeScanner()

        XCTAssertEqual(try scanner.scan(OpticalFrame(image: blankImage, frameID: 1, monotonicTimestamp: 0)), [])
        XCTAssertEqual(try scanner.scan(OpticalFrame(image: barcodeImage, frameID: 2, monotonicTimestamp: 1)), [])
    }

    func testRendererRejectsEmptyOversizedPayloadAndInvalidScale() {
        let renderer = OpticalQRCodeRenderer()
        XCTAssertThrowsError(try renderer.render(payload: Data(), moduleScale: 8))
        XCTAssertThrowsError(try renderer.render(payload: Data(repeating: 1, count: 1_201), moduleScale: 8))
        XCTAssertThrowsError(try renderer.render(payload: Data("valid".utf8), moduleScale: 0))
    }

    private func goldenOffer() -> OpticalMessage {
        OpticalMessage(missionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .offer, sequence: 1, role: .a, markerID: "SILENT_SEARCH_01",
            timestampMilliseconds: 1_786_406_400_000,
            body: .offer(OfferBody(searchDurationSeconds: 180, centerHalfWidthMillimeters: 250,
                targetLabel: "chair", markerWidthMillimeters: 200,
                roverARendezvous: OpticalPose(x: -600, y: -800, headingMillidegrees: 0),
                roverBRendezvous: OpticalPose(x: 600, y: -800, headingMillidegrees: 0))))
    }

    private func goldenMessages() -> [OpticalMessage] {
        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "b", count: 64)
        let missionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let timestamp: Int64 = 1_786_406_400_000
        func message(_ kind: OpticalMessageKind, _ body: OpticalMessageBody,
                     role: RoverRole = .a, sequence: UInt64) -> OpticalMessage {
            OpticalMessage(missionID: missionID, kind: kind, sequence: sequence, role: role,
                markerID: "SILENT_SEARCH_01", timestampMilliseconds: timestamp, body: body)
        }
        return [
            goldenOffer(),
            message(.accept, .accept(AcceptBody(offerHash: hashA,
                roverBWallTimeMilliseconds: timestamp)), role: .b, sequence: 1),
            message(.searchCommit, .searchCommit(SearchCommitBody(deadlineMilliseconds: timestamp + 210_000,
                acceptanceHash: hashB, startMilliseconds: timestamp + 30_000)), sequence: 2),
            message(.searchAck, .searchAck(HashAcknowledgementBody(hash: hashA)), role: .b, sequence: 2),
            message(.status, .status(StatusBody(found: true, label: "chair", x: -100, y: 200,
                confidenceBasisPoints: 9500, sampleCount: 3)), sequence: 3),
            message(.decision, .decision(DecisionBody(roverAStatusHash: hashA, roverBStatusHash: hashB,
                outcome: .found, x: -100, y: 200)), sequence: 4),
            message(.converge, .converge(ConvergeBody(decisionHash: hashA,
                releaseMilliseconds: timestamp + 300_000, x: -100, y: 200)), sequence: 5),
            message(.convergeAck, .convergeAck(HashAcknowledgementBody(hash: hashB)),
                role: .b, sequence: 4)
        ]
    }

    private func largestStatus() -> OpticalMessage {
        OpticalMessage(missionID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            kind: .status, sequence: .max, role: .b, markerID: "ABCDEFGHIJKLMNOPQRSTUVWX",
            timestampMilliseconds: .max,
            body: .status(StatusBody(found: true, previousStatusHash: String(repeating: "f", count: 64),
                label: String(repeating: "z", count: 40), x: .min, y: .max,
                confidenceBasisPoints: 10_000, sampleCount: .max)))
    }

    private func largestDecision() -> OpticalMessage {
        OpticalMessage(missionID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            kind: .decision, sequence: .max, role: .a, markerID: "ABCDEFGHIJKLMNOPQRSTUVWX",
            timestampMilliseconds: .max,
            body: .decision(DecisionBody(roverAStatusHash: String(repeating: "a", count: 64),
                roverBStatusHash: String(repeating: "b", count: 64), outcome: .found,
                x: .min, y: .max)))
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    private func assertCorners(
        _ actual: OrientedMarkerCorners,
        equalTo expected: OrientedMarkerCorners,
        orientation: CGImagePropertyOrientation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (actualPoint, expectedPoint) in [
            (actual.topLeft, expected.topLeft), (actual.topRight, expected.topRight),
            (actual.bottomLeft, expected.bottomLeft), (actual.bottomRight, expected.bottomRight),
        ] {
            XCTAssertEqual(actualPoint.x, expectedPoint.x, accuracy: 0.000_001,
                           "Unexpected x coordinate for \(orientation)", file: file, line: line)
            XCTAssertEqual(actualPoint.y, expectedPoint.y, accuracy: 0.000_001,
                           "Unexpected y coordinate for \(orientation)", file: file, line: line)
        }
    }
}
