import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision

protocol ScreenLocalizing: AnyObject {
    var isLoaded: Bool { get }
    func detect(_ pixelBuffer: CVPixelBuffer) -> [Detector.Detection]
}

final class VisionScreenLocalizer: ScreenLocalizing {
    private var request: VNCoreMLRequest?
    var isLoaded: Bool { request != nil }

    init(modelName: String = "RoverYOLO") async {
        guard let modelURL = Detector.modelResourceURL(modelName: modelName) else {
            RuntimeFileLog.append("screen_detector_unavailable", fields: [
                "model": modelName,
                "reason": "model_resource_missing",
            ])
            return
        }

        do {
            let loadURL = modelURL.pathExtension == "mlmodelc"
                ? modelURL
                : try await MLModel.compileModel(at: modelURL)
            let model = try MLModel(contentsOf: loadURL, configuration: Detector.modelConfiguration())
            let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            request.imageCropAndScaleOption = .scaleFill
            self.request = request
            RuntimeFileLog.append("screen_detector_loaded", fields: [
                "resource": modelURL.lastPathComponent,
            ])
        } catch {
            RuntimeFileLog.append("screen_detector_unavailable", fields: [
                "error": error.localizedDescription,
                "reason": "model_load_failed",
                "resource": modelURL.lastPathComponent,
            ])
        }
    }

    func detect(_ pixelBuffer: CVPixelBuffer) -> [Detector.Detection] {
        guard let request else { return [] }
        for orientation in Detector.detectionOrientations(preferred: .right) {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            do {
                try handler.perform([request])
            } catch {
                RuntimeFileLog.append("screen_detector_failed", fields: [
                    "error": error.localizedDescription,
                    "orientation": "\(orientation.rawValue)",
                ])
                continue
            }
            guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                continue
            }
            let detections = observations.compactMap { observation -> Detector.Detection? in
                guard let label = observation.labels.first else { return nil }
                return Detector.Detection(
                    label: label.identifier,
                    confidence: label.confidence,
                    boundingBox: observation.boundingBox
                )
            }.filter { ScreenDetectionPolicy.isScreenLike($0.label) }
            if !detections.isEmpty { return detections }
        }
        return []
    }
}
