import XCTest
@testable import LiveTranslate

@MainActor
final class CaptionPiPStartupCoordinatorTests: XCTestCase {
    func testControllerIsNotConfiguredBeforeMountAndMountConfiguresOnce() {
        let coordinator = makeCoordinator()

        XCTAssertFalse(coordinator.isConfigured)
        XCTAssertTrue(coordinator.hostDidMount())
        XCTAssertTrue(coordinator.isConfigured)
        XCTAssertFalse(coordinator.hostDidMount())
    }

    func testAudioPreparationPrecedesStartRequest() {
        let events = EventRecorder()
        let coordinator = makeCoordinator(events: events)
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(true)

        coordinator.requestStart()

        XCTAssertEqual(events.events, ["prepareAudio", "startPictureInPicture"])
    }

    func testAudioPreparationFailureBecomesVisibleStartFailure() {
        let audioSession = RecordingAudioSessionPreparer(error: StartupTestError.audioUnavailable)
        let coordinator = CaptionPiPStartupCoordinator(
            audioSession: audioSession,
            startPictureInPicture: {}
        )
        _ = coordinator.hostDidMount()

        coordinator.requestStart()

        XCTAssertEqual(coordinator.state, .failed("画中画字幕启动失败：音频会话准备失败：模拟音频不可用"))
        XCTAssertEqual(coordinator.state.statusMessage, "画中画字幕启动失败：音频会话准备失败：模拟音频不可用")
    }

    func testPendingReadinessAutomaticallyStartsOnceWhenItBecomesPossible() {
        let events = EventRecorder()
        let coordinator = makeCoordinator(events: events)
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(false)

        coordinator.requestStart()
        XCTAssertEqual(coordinator.state, .pending)

        coordinator.readinessDidChange(true)
        coordinator.readinessDidChange(true)

        XCTAssertEqual(coordinator.state, .active)
        XCTAssertEqual(events.events, ["prepareAudio", "startPictureInPicture"])
    }

    func testPendingRequestTimesOutWithVisibleFailure() {
        let coordinator = makeCoordinator()
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(false)

        coordinator.requestStart()
        coordinator.timeoutElapsed()

        XCTAssertEqual(coordinator.state, .failed("画中画字幕启动失败：等待系统准备超时，请重试。"))
    }

    func testStopPreventsLateReadinessOrTimeoutFromStartingPictureInPicture() {
        let events = EventRecorder()
        let coordinator = makeCoordinator(events: events)
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(false)
        coordinator.requestStart()

        coordinator.stop()
        coordinator.readinessDidChange(true)
        coordinator.timeoutElapsed()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(events.events, ["prepareAudio"])
    }

    private func makeCoordinator(events: EventRecorder = EventRecorder()) -> CaptionPiPStartupCoordinator {
        CaptionPiPStartupCoordinator(
            audioSession: RecordingAudioSessionPreparer(events: events),
            startPictureInPicture: { events.events.append("startPictureInPicture") }
        )
    }
}

@MainActor
private final class EventRecorder {
    var events: [String] = []
}

@MainActor
private final class RecordingAudioSessionPreparer: CaptionPiPAudioSessionPreparing {
    private let events: EventRecorder?
    private let error: (any Error)?

    init(events: EventRecorder? = nil, error: (any Error)? = nil) {
        self.events = events
        self.error = error
    }

    func prepareForPictureInPicture() throws {
        events?.events.append("prepareAudio")
        if let error {
            throw error
        }
    }
}

private enum StartupTestError: LocalizedError {
    case audioUnavailable

    var errorDescription: String? {
        "模拟音频不可用"
    }
}
