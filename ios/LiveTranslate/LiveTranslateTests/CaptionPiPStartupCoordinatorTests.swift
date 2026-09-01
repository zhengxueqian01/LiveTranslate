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
        XCTAssertEqual(audioSession.events.events, ["prepareAudio", "releaseAudio"])
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

    func testPendingRequestTimesOutWithVisibleFailureAndReleasesAudioSession() async {
        let events = EventRecorder()
        let coordinator = makeCoordinator(events: events, timeout: .milliseconds(10))
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(false)

        coordinator.requestStart()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(coordinator.state, .failed("画中画字幕启动失败：等待系统准备超时，请重试。"))
        XCTAssertEqual(events.events, ["prepareAudio", "releaseAudio"])
    }

    func testStopCancelsAsyncTimeoutAndPreventsLateReadinessFromStartingPictureInPicture() async {
        let events = EventRecorder()
        let coordinator = makeCoordinator(events: events, timeout: .milliseconds(10))
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(false)
        coordinator.requestStart()

        coordinator.stop()
        coordinator.readinessDidChange(true)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(events.events, ["prepareAudio", "releaseAudio"])
    }

    func testStartFailureReleasesAudioSessionOnlyOnce() {
        let events = EventRecorder()
        let coordinator = makeCoordinator(events: events)
        _ = coordinator.hostDidMount()
        coordinator.readinessDidChange(true)

        coordinator.requestStart()
        coordinator.didFailToStart(errorDescription: "系统拒绝启动")
        coordinator.stop()

        XCTAssertEqual(
            events.events,
            ["prepareAudio", "startPictureInPicture", "releaseAudio"]
        )
    }

    private func makeCoordinator(
        events: EventRecorder = EventRecorder(),
        timeout: Duration = .seconds(5)
    ) -> CaptionPiPStartupCoordinator {
        CaptionPiPStartupCoordinator(
            audioSession: RecordingAudioSessionPreparer(events: events),
            startPictureInPicture: { events.events.append("startPictureInPicture") },
            timeout: timeout
        )
    }
}

@MainActor
private final class EventRecorder {
    var events: [String] = []
}

@MainActor
private final class RecordingAudioSessionPreparer: CaptionPiPAudioSessionPreparing {
    let events: EventRecorder
    private let error: (any Error)?

    init(events: EventRecorder = EventRecorder(), error: (any Error)? = nil) {
        self.events = events
        self.error = error
    }

    func prepareForPictureInPicture() throws {
        events.events.append("prepareAudio")
        if let error {
            throw error
        }
    }

    func releasePictureInPictureAudioSession() {
        events.events.append("releaseAudio")
    }
}

private enum StartupTestError: LocalizedError {
    case audioUnavailable

    var errorDescription: String? {
        "模拟音频不可用"
    }
}
