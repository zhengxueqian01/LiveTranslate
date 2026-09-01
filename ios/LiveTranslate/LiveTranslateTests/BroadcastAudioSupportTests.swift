import Foundation
import XCTest
@testable import LiveTranslate

final class BroadcastAudioSupportTests: XCTestCase {
    func testBoundedQueuePreservesFIFOAndRejectsOverflow() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 2)

        try queue.yield(1)
        try queue.yield(2)
        XCTAssertThrowsError(try queue.yield(3)) { error in
            XCTAssertEqual(error as? BoundedAsyncQueueError, .dropped)
        }
        queue.finish()

        var values: [Int] = []
        for await value in queue.stream {
            values.append(value)
        }
        XCTAssertEqual(values, [1, 2])
    }

    func testBoundedQueueRejectsYieldAfterFinish() {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)

        queue.finish()

        XCTAssertThrowsError(try queue.yield(1)) { error in
            XCTAssertEqual(error as? BoundedAsyncQueueError, .terminated)
        }
    }

    func testFailedCaptionStateCannotBeOverwrittenByLateUpdates() throws {
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(store: store)
        try coordinator.begin()

        try coordinator.fail(message: "识别失败")
        try coordinator.updateText("迟到文本")
        try coordinator.reportSilence(message: "迟到静音")
        try coordinator.stop()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.sourceText, "")
        XCTAssertEqual(snapshot.errorMessage, "识别失败")
    }

    func testStoppedCaptionStateCannotReturnToRecognizing() throws {
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(store: store)
        try coordinator.begin()

        try coordinator.stop()
        try coordinator.updateText("迟到文本")
        try coordinator.reportSilence(message: "迟到静音")

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.phase, .stopped)
        XCTAssertEqual(snapshot.sourceText, "")
        XCTAssertNil(snapshot.errorMessage)
    }

    func testTextPreservesSilenceWarningUntilAudibleRecovery() throws {
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(store: store)
        try coordinator.begin()
        try coordinator.markRecognizing()
        try coordinator.reportSilence(message: "来源静音")

        try coordinator.updateText("hello")

        var snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "hello")
        XCTAssertEqual(snapshot.errorMessage, "来源静音")

        try coordinator.clearSilenceWarning()

        snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "hello")
        XCTAssertNil(snapshot.errorMessage)
    }

    func testSilenceTimerFreezesWhilePausedAndRestartsOnResume() {
        var state = SilenceMonitorState()
        state.start(at: .seconds(0))

        state.pause()
        XCTAssertFalse(state.takeWarningIfDue(at: .seconds(10), after: .seconds(3)))

        state.resume(at: .seconds(10))
        XCTAssertFalse(state.takeWarningIfDue(at: .seconds(12), after: .seconds(3)))
        XCTAssertTrue(state.takeWarningIfDue(at: .seconds(13), after: .seconds(3)))
        XCTAssertFalse(state.takeWarningIfDue(at: .seconds(14), after: .seconds(3)))
    }
}
