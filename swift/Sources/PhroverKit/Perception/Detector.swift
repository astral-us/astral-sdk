import Foundation
import Vision
import CoreML
import CoreVideo

/// On-device object detector (person + generic obstacles) via a CoreML model wrapped
/// in Vision. Ships with a bundled YOLO-family `.mlpackage`; swap the model name to use
/// a custom-trained one.
///
/// Detections feed two consumers: `ObstacleGuard` (people directly ahead) and dialog/
/// "who's there" behaviors. This is the on-device half of the hybrid AI split — heavy
/// vision-language reasoning can be offloaded to the cloud via `DialogEscalating`.
public final class Detector {
    public struct Detection: Sendable {
        public let label: String
        public let confidence: Float
        public let boundingBox: CGRect // normalized, Vision coords
    }

    private var request: VNCoreMLRequest?

    /// Compiles the bundled `.mlpackage` at load time (SwiftPM resource bundles ship the
    /// package uncompiled, unlike an Xcode app target which auto-compiles it at build time).
    public init(modelName: String = "RoverYOLO") async {
        guard let packageURL = Bundle.module.url(forResource: modelName, withExtension: "mlpackage"),
              let compiledURL = try? await MLModel.compileModel(at: packageURL),
              let model = try? VNCoreMLModel(for: MLModel(contentsOf: compiledURL)) else {
            request = nil
            return
        }
        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .scaleFill
        request = req
    }

    public func detect(_ pixelBuffer: CVPixelBuffer) -> [Detection] {
        guard let request else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
        return results.map {
            Detection(label: $0.labels.first?.identifier ?? "object",
                      confidence: $0.labels.first?.confidence ?? 0,
                      boundingBox: $0.boundingBox)
        }
    }
}
