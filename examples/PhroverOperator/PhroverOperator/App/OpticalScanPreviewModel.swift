import CoreImage
import Observation
import PhroverKit
import UIKit

@MainActor
@Observable
final class OpticalScanPreviewModel {
    typealias Renderer = @MainActor (ARFrameSnapshot) -> UIImage?

    private(set) var image: UIImage?
    @ObservationIgnored private let frames: @MainActor () -> AsyncStream<ARFrameSnapshot>
    @ObservationIgnored private let render: Renderer
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        frames: @escaping @MainActor () -> AsyncStream<ARFrameSnapshot>,
        render: @escaping Renderer
    ) {
        self.frames = frames
        self.render = render
    }

    convenience init(frames: @escaping @MainActor () -> AsyncStream<ARFrameSnapshot>) {
        let context = CIContext()
        self.init(frames: frames) { snapshot in
            let image = CIImage(cvPixelBuffer: snapshot.image).oriented(.right)
            guard let rendered = context.createCGImage(image, from: image.extent) else { return nil }
            return UIImage(cgImage: rendered)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, frames] in
            for await snapshot in frames() {
                guard let self, !Task.isCancelled else { return }
                image = render(snapshot)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        image = nil
    }
}
