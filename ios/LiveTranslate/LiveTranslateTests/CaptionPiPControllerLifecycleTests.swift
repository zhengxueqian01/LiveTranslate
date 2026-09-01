@preconcurrency import AVFoundation
@preconcurrency import AVKit
import XCTest
import UIKit
@testable import LiveTranslate

@MainActor
final class CaptionPiPControllerLifecycleTests: XCTestCase {
    func testControllerCreatesPiPLifecycleOnlyAfterMountedHostAndOnlyOnce() {
        let factory = RecordingPiPLifecycleFactory()
        let controller = CaptionPiPController(
            pictureInPictureFactory: factory,
            isPictureInPictureSupported: { true }
        )

        XCTAssertEqual(factory.makeCount, 0)

        mount(controller.hostView)
        XCTAssertEqual(factory.makeCount, 1)

        controller.hostView.setNeedsLayout()
        controller.hostView.layoutIfNeeded()
        XCTAssertEqual(factory.makeCount, 1)
    }

    func testQueuedReadinessCannotStartAfterExplicitStopAndReleaseIsIdempotent() async {
        let factory = RecordingPiPLifecycleFactory()
        let audioSession = RecordingLifecycleAudioSession()
        let controller = CaptionPiPController(
            audioSession: audioSession,
            pictureInPictureFactory: factory,
            isPictureInPictureSupported: { true }
        )
        mount(controller.hostView)

        controller.start()
        factory.lifecycle.queueReadiness(true)
        controller.stop()
        factory.lifecycle.emitDidStop()
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        XCTAssertEqual(factory.lifecycle.startCount, 0)
        XCTAssertEqual(audioSession.events, ["prepareAudio", "releaseAudio"])
    }

    func testQueuedReadinessCannotStartAfterControllerDeinitAndReleasesAudio() async {
        let factory = RecordingPiPLifecycleFactory()
        let audioSession = RecordingLifecycleAudioSession()
        var controller: CaptionPiPController? = CaptionPiPController(
            audioSession: audioSession,
            pictureInPictureFactory: factory,
            isPictureInPictureSupported: { true }
        )
        mount(controller!.hostView)

        controller!.start()
        factory.lifecycle.queueReadiness(true)
        controller = nil
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        XCTAssertEqual(factory.lifecycle.startCount, 0)
        XCTAssertEqual(audioSession.events, ["prepareAudio", "releaseAudio"])
    }

    private func mount(_ hostView: CaptionPiPHostView) {
        hostView.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.view.addSubview(hostView)
        rootViewController.view.layoutIfNeeded()
        hostView.layoutIfNeeded()
    }
}

@MainActor
private final class RecordingPiPLifecycleFactory: CaptionPiPLifecycleFactory {
    let lifecycle = RecordingPiPLifecycle()
    private(set) var makeCount = 0

    func makePictureInPictureLifecycle(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer,
        playbackDelegate: AVPictureInPictureSampleBufferPlaybackDelegate
    ) -> any CaptionPiPLifecycleControlling {
        makeCount += 1
        return lifecycle
    }
}

@MainActor
private final class RecordingPiPLifecycle: CaptionPiPLifecycleControlling {
    private var readinessHandler: ((Bool) -> Void)?
    private var didStopHandler: (() -> Void)?
    private var startFailureHandler: ((String) -> Void)?
    private(set) var startCount = 0

    func setEventHandlers(
        didStop: @escaping () -> Void,
        didFailToStart: @escaping (String) -> Void
    ) {
        didStopHandler = didStop
        startFailureHandler = didFailToStart
    }

    func startPictureInPicture() {
        startCount += 1
    }

    func stopPictureInPicture() {}

    func observeReadiness(
        _ handler: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> any CaptionPiPReadinessObserving {
        readinessHandler = handler
        return RecordingReadinessObservation { [weak self] in
            self?.readinessHandler = nil
        }
    }

    func queueReadiness(_ isPossible: Bool) {
        let handler = readinessHandler
        Task { @MainActor in
            handler?(isPossible)
        }
    }

    func emitDidStop() {
        didStopHandler?()
    }
}

@MainActor
private final class RecordingReadinessObservation: CaptionPiPReadinessObserving {
    private let invalidateHandler: () -> Void
    private var isInvalidated = false

    init(invalidateHandler: @escaping () -> Void) {
        self.invalidateHandler = invalidateHandler
    }

    func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        invalidateHandler()
    }
}

@MainActor
private final class RecordingLifecycleAudioSession: CaptionPiPAudioSessionPreparing {
    private(set) var events: [String] = []

    func prepareForPictureInPicture() throws {
        events.append("prepareAudio")
    }

    func releasePictureInPictureAudioSession() {
        events.append("releaseAudio")
    }
}
