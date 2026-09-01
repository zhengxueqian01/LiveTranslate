@preconcurrency import AVFoundation
@preconcurrency import AVKit
import Foundation

@MainActor
protocol CaptionPiPReadinessObserving: AnyObject, Sendable {
    func invalidate()
}

@MainActor
protocol CaptionPiPLifecycleControlling: AnyObject {
    func setEventHandlers(
        didStop: @escaping () -> Void,
        didFailToStart: @escaping (String) -> Void
    )
    func startPictureInPicture()
    func stopPictureInPicture()
    func observeReadiness(
        _ handler: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> any CaptionPiPReadinessObserving
}

@MainActor
protocol CaptionPiPLifecycleFactory: AnyObject {
    func makePictureInPictureLifecycle(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer,
        playbackDelegate: AVPictureInPictureSampleBufferPlaybackDelegate
    ) -> any CaptionPiPLifecycleControlling
}

@MainActor
final class SystemCaptionPiPLifecycleFactory: CaptionPiPLifecycleFactory {
    func makePictureInPictureLifecycle(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer,
        playbackDelegate: AVPictureInPictureSampleBufferPlaybackDelegate
    ) -> any CaptionPiPLifecycleControlling {
        SystemCaptionPiPLifecycle(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: playbackDelegate
        )
    }
}

@MainActor
private final class SystemCaptionPiPLifecycle: NSObject, CaptionPiPLifecycleControlling {
    private let pictureInPictureController: AVPictureInPictureController
    private var didStop: (() -> Void)?
    private var didFailToStart: ((String) -> Void)?

    init(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer,
        playbackDelegate: AVPictureInPictureSampleBufferPlaybackDelegate
    ) {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: playbackDelegate
        )
        pictureInPictureController = AVPictureInPictureController(contentSource: source)
        super.init()
        pictureInPictureController.delegate = self
    }

    func setEventHandlers(
        didStop: @escaping () -> Void,
        didFailToStart: @escaping (String) -> Void
    ) {
        self.didStop = didStop
        self.didFailToStart = didFailToStart
    }

    func startPictureInPicture() {
        pictureInPictureController.startPictureInPicture()
    }

    func stopPictureInPicture() {
        pictureInPictureController.stopPictureInPicture()
    }

    func observeReadiness(
        _ handler: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> any CaptionPiPReadinessObserving {
        let observation = pictureInPictureController.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { controller, _ in
            Task { @MainActor in
                handler(controller.isPictureInPicturePossible)
            }
        }
        return SystemCaptionPiPReadinessObservation(observation: observation)
    }
}

extension SystemCaptionPiPLifecycle: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        didStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        didFailToStart?(error.localizedDescription)
    }
}

@MainActor
private final class SystemCaptionPiPReadinessObservation: CaptionPiPReadinessObserving {
    private var observation: NSKeyValueObservation?

    init(observation: NSKeyValueObservation) {
        self.observation = observation
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
    }

}
