import Foundation
import Vision
import CoreML
import CoreVideo
import ImageIO

/// On-device object detector (person + generic obstacles) via a CoreML model wrapped
/// in Vision. Ships with a bundled YOLO-family `.mlpackage`; swap the model name to use
/// a custom-trained one.
///
/// Detections feed two consumers: `ObstacleGuard` (people directly ahead) and dialog/
/// "who's there" behaviors. This is the on-device half of the hybrid AI split — heavy
/// vision-language reasoning can be offloaded to the cloud via `DialogEscalating`.
public final class Detector {
    public enum EvaluationStatus: String, Sendable { case executed, failed }
    public enum FailureReason: String, Sendable {
        case unavailable = "detector_unavailable", inferenceFailed = "inference_failed"
    }
    public struct EvaluationReceipt: Sendable {
        public let frame: FrameDetections
        public let status: EvaluationStatus
        public let failureReason: FailureReason?
        /// Orientation actually evaluated for these boxes; nil for unknown legacy handlers/failure.
        public let orientation: CGImagePropertyOrientation?
    }
    public struct Detection: Sendable {
        public let label: String
        public let confidence: Float
        public let boundingBox: CGRect // normalized, Vision coords
    }

    public struct FrameDetections: Sendable {
        public let frameID: ARFrameID
        public let monotonicTimestamp: TimeInterval
        public let detections: [Detection]

        public init(frameID: ARFrameID, monotonicTimestamp: TimeInterval, detections: [Detection]) {
            self.frameID = frameID
            self.monotonicTimestamp = monotonicTimestamp
            self.detections = detections
        }
    }

    private var request: VNCoreMLRequest?
    private let detectionHandler: ((CVPixelBuffer) throws -> [Detection])?
    private var visionHandler: ((CVPixelBuffer, CGImagePropertyOrientation) throws -> [Detection])?
    public var isLoaded: Bool { request != nil }
    public private(set) var supportedCanonicalLabels: Set<String> = []

    /// Loads Xcode's compiled `.mlmodelc` when available, with source model fallback for
    /// package contexts that still ship `.mlpackage`/`.mlmodel` resources.
    public init(modelName: String = "RoverYOLO") async {
        detectionHandler = nil
        guard let modelURL = Self.modelResourceURL(modelName: modelName) else {
            request = nil
            RuntimeFileLog.append("detector_unavailable", fields: [
                "reason": "model_resource_missing",
                "model": modelName
            ])
            return
        }

        do {
            let loadURL: URL
            if modelURL.pathExtension == "mlmodelc" {
                loadURL = modelURL
            } else {
                loadURL = try await MLModel.compileModel(at: modelURL)
            }
            let coreMLModel = try MLModel(contentsOf: loadURL, configuration: Self.modelConfiguration())
            supportedCanonicalLabels = Self.canonicalLabels(from: coreMLModel.modelDescription.classLabels ?? [])
            let model = try VNCoreMLModel(for: coreMLModel)
            let req = VNCoreMLRequest(model: model)
            req.imageCropAndScaleOption = .scaleFill
            request = req
            RuntimeFileLog.append("detector_loaded", fields: [
                "resource": modelURL.lastPathComponent
            ])
        } catch {
            request = nil
            RuntimeFileLog.append("detector_unavailable", fields: [
                "reason": "model_load_failed",
                "resource": modelURL.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    init(supportedLabels: Set<String>, detectionHandler: @escaping (CVPixelBuffer) throws -> [Detection]) {
        request = nil
        self.detectionHandler = detectionHandler
        supportedCanonicalLabels = supportedLabels
    }

    /// Exercises the same orientation selection as the production Vision request.
    init(supportedLabels: Set<String>, visionHandler: @escaping (CVPixelBuffer, CGImagePropertyOrientation) throws -> [Detection]) {
        request = nil
        detectionHandler = nil
        self.visionHandler = visionHandler
        supportedCanonicalLabels = supportedLabels
    }

    static func modelResourceURL(modelName: String, bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: modelName, withExtension: "mlmodelc")
            ?? bundle.url(forResource: modelName, withExtension: "mlpackage")
            ?? bundle.url(forResource: modelName, withExtension: "mlmodel")
    }

    static func modelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        // iOS denies GPU/Metal command buffers once the app is backgrounded. Keeping the
        // detector off GPU avoids MPSGraph background-execution crashes from live preview
        // or mission perception work that is winding down during app lifecycle changes.
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    static func canonicalLabels(from classLabels: [Any]) -> Set<String> {
        Set(classLabels.compactMap { $0 as? String })
    }

    public func detect(_ pixelBuffer: CVPixelBuffer) -> [Detection] {
        evaluate(pixelBuffer).detections
    }

    private func evaluate(_ pixelBuffer: CVPixelBuffer,
                          orientations: [CGImagePropertyOrientation] = Detector.detectionOrientations(preferred: .right))
        -> (detections: [Detection], reason: FailureReason?, orientation: CGImagePropertyOrientation?) {
        if let detectionHandler {
            do { return (try detectionHandler(pixelBuffer), nil, nil) }
            catch { return ([], .inferenceFailed, nil) }
        }
        guard request != nil || visionHandler != nil else { return ([], .unavailable, nil) }
        var failed = false
        var evaluatedOrientation: CGImagePropertyOrientation?
        for orientation in orientations {
            do {
                let detections: [Detection]
                if let visionHandler { detections = try visionHandler(pixelBuffer, orientation) }
                else if let request { detections = try detect(pixelBuffer, request: request, orientation: orientation) }
                else { return ([], .unavailable, nil) }
                evaluatedOrientation = orientation
                if !detections.isEmpty { return (detections, nil, orientation) }
            } catch { failed = true }
        }
        return ([], failed ? .inferenceFailed : nil, failed ? nil : evaluatedOrientation)
    }

    public func evaluate(_ snapshot: ARFrameSnapshot) -> EvaluationReceipt {
        let result = evaluate(snapshot.image)
        return EvaluationReceipt(frame: .init(frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                                             detections: result.detections),
                                 status: result.reason == nil ? .executed : .failed, failureReason: result.reason,
                                 orientation: result.orientation)
    }

    /// Follow projection uses the inverse .right transform; never feed fallback boxes to it.
    public func evaluateForFollow(_ snapshot: ARFrameSnapshot) -> EvaluationReceipt {
        let result = evaluate(snapshot.image, orientations: [.right])
        return EvaluationReceipt(frame: .init(frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                                             detections: result.detections),
                                 status: result.reason == nil ? .executed : .failed,
                                 failureReason: result.reason, orientation: result.orientation)
    }

    public func detect(_ snapshot: ARFrameSnapshot) -> FrameDetections {
        FrameDetections(frameID: snapshot.id, monotonicTimestamp: snapshot.timestamp,
                        detections: detect(snapshot.image))
    }

    static func detectionOrientations(preferred: CGImagePropertyOrientation) -> [CGImagePropertyOrientation] {
        var orientations = [preferred]
        for fallback in [CGImagePropertyOrientation.right, .up, .left, .down] where fallback != preferred {
            orientations.append(fallback)
        }
        return orientations
    }

    private func detect(_ pixelBuffer: CVPixelBuffer,
                        request: VNCoreMLRequest,
                         orientation: CGImagePropertyOrientation) throws -> [Detection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            throw error
        }
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
        return results.map {
            Detection(label: $0.labels.first?.identifier ?? "object",
                      confidence: $0.labels.first?.confidence ?? 0,
                      boundingBox: $0.boundingBox)
        }
    }
}
