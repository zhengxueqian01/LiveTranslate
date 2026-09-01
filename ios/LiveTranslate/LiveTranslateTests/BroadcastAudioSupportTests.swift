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

    func testAppendIsRejectedOnceFinishStarts() async throws {
        let operations = ControlledSpeechPipelineOperations(
            waitsForFinalizeRelease: true
        )
        let lifecycle = SpeechPipelineLifecycle(operations: operations)

        let appendedValue = try await lifecycle.append(1)
        XCTAssertEqual(appendedValue, 1)
        let finishTask = Task {
            try await lifecycle.finish()
        }
        await operations.waitUntilFinalizeStarts()

        do {
            _ = try await lifecycle.append(2)
            XCTFail("Append must not succeed after finish starts")
        } catch {
            XCTAssertEqual(error as? SpeechPipelineLifecycleError, .finished)
        }

        operations.releaseFinalize()
        try await finishTask.value
        XCTAssertEqual(
            operations.events,
            [.append(1), .drainTail, .finishInput, .finalize, .cancelResults, .awaitResults]
        )
    }

    func testFinishFailureStillCleansResourcesAndRepeatedFinishIsIdempotent() async {
        let operations = ControlledSpeechPipelineOperations(drainError: .drainFailed)
        let lifecycle = SpeechPipelineLifecycle(operations: operations)

        let firstError = await capturedError {
            try await lifecycle.finish()
        }
        let secondError = await capturedError {
            try await lifecycle.finish()
        }

        XCTAssertEqual(firstError as? ControlledSpeechPipelineOperations.TestError, .drainFailed)
        XCTAssertEqual(secondError as? ControlledSpeechPipelineOperations.TestError, .drainFailed)
        XCTAssertEqual(
            operations.events,
            [.drainTail, .finishInput, .cancelAnalyzer, .cancelResults, .awaitResults]
        )

        do {
            _ = try await lifecycle.append(1)
            XCTFail("Append must not succeed after failed termination")
        } catch {
            XCTAssertEqual(error as? SpeechPipelineLifecycleError, .finished)
        }
    }

    private func capturedError(
        _ operation: () async throws -> Void
    ) async -> (any Error)? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }
}

private final class ControlledSpeechPipelineOperations:
    SpeechPipelineLifecycleOperations,
    @unchecked Sendable
{
    enum TestError: Error, Equatable {
        case drainFailed
    }

    enum Event: Equatable {
        case append(Int)
        case drainTail
        case finishInput
        case finalize
        case cancelAnalyzer
        case cancelResults
        case awaitResults
    }

    typealias Sample = Int
    typealias AppendResult = Int

    private let lock = NSLock()
    private let drainError: TestError?
    private let waitsForFinalizeRelease: Bool
    private let finalizeStarted: AsyncStream<Void>
    private let finalizeStartedContinuation: AsyncStream<Void>.Continuation
    private let finalizeRelease: AsyncStream<Void>
    private let finalizeReleaseContinuation: AsyncStream<Void>.Continuation
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    init(
        drainError: TestError? = nil,
        waitsForFinalizeRelease: Bool = false
    ) {
        self.drainError = drainError
        self.waitsForFinalizeRelease = waitsForFinalizeRelease
        let startedPair = AsyncStream.makeStream(of: Void.self)
        finalizeStarted = startedPair.stream
        finalizeStartedContinuation = startedPair.continuation
        let releasePair = AsyncStream.makeStream(of: Void.self)
        finalizeRelease = releasePair.stream
        finalizeReleaseContinuation = releasePair.continuation
    }

    func append(_ sample: Int) throws -> Int {
        record(.append(sample))
        return sample
    }

    func drainTail() throws {
        record(.drainTail)
        if let drainError {
            throw drainError
        }
    }

    func finishInput() {
        record(.finishInput)
    }

    func finalizeAnalyzer() async throws {
        record(.finalize)
        finalizeStartedContinuation.yield()
        guard waitsForFinalizeRelease else { return }
        for await _ in finalizeRelease {
            return
        }
    }

    func cancelAnalyzer() async {
        record(.cancelAnalyzer)
    }

    func cancelResults() {
        record(.cancelResults)
    }

    func awaitResults() async throws {
        record(.awaitResults)
    }

    func waitUntilFinalizeStarts() async {
        for await _ in finalizeStarted {
            return
        }
    }

    func releaseFinalize() {
        finalizeReleaseContinuation.yield()
        finalizeReleaseContinuation.finish()
    }

    private func record(_ event: Event) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
