import Foundation
import XCTest
@testable import LiveTranslate

final class BroadcastAudioSupportTests: XCTestCase {
    func testAsyncSendWaitsForCapacityBeforeCompleting() async throws {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        try await queue.send(1)

        let sendStarted = expectation(description: "send started")
        let sendFinished = expectation(description: "send finished")
        sendFinished.isInverted = true
        let sendTask = Task {
            sendStarted.fulfill()
            try await queue.send(2)
            sendFinished.fulfill()
        }

        await fulfillment(of: [sendStarted], timeout: 1)
        await fulfillment(of: [sendFinished], timeout: 0.05)

        var iterator = queue.stream.makeAsyncIterator()
        let firstValue = await iterator.next()
        XCTAssertEqual(firstValue, 1)
        try await sendTask.value
        let secondValue = await iterator.next()
        XCTAssertEqual(secondValue, 2)
    }

    func testAsyncSendResumesWaitingProducersInFIFOOrder() async throws {
        let suspendedSendPair = AsyncStream.makeStream(of: Int.self)
        let suspendedSendContinuation = suspendedSendPair.continuation
        let queue = BoundedAsyncQueue<Int>(
            capacity: 1,
            onSendSuspended: { value in
                suspendedSendContinuation.yield(value)
            }
        )
        var suspendedSends = suspendedSendPair.stream.makeAsyncIterator()
        try await queue.send(1)

        let secondTask = Task {
            try await queue.send(2)
        }
        let secondSuspendedValue = await suspendedSends.next()
        XCTAssertEqual(secondSuspendedValue, 2)

        let thirdTask = Task {
            try await queue.send(3)
        }
        let thirdSuspendedValue = await suspendedSends.next()
        XCTAssertEqual(thirdSuspendedValue, 3)

        var iterator = queue.stream.makeAsyncIterator()
        let firstValue = await iterator.next()
        let secondValue = await iterator.next()
        let thirdValue = await iterator.next()
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(thirdValue, 3)
        try await secondTask.value
        try await thirdTask.value
    }

    func testFinishTerminatesBlockedSendAndDrainsAcceptedElements() async throws {
        let suspendedSendPair = AsyncStream.makeStream(of: Int.self)
        let suspendedSendContinuation = suspendedSendPair.continuation
        let queue = BoundedAsyncQueue<Int>(
            capacity: 1,
            onSendSuspended: { value in
                suspendedSendContinuation.yield(value)
            }
        )
        var suspendedSends = suspendedSendPair.stream.makeAsyncIterator()
        try await queue.send(1)

        let sendTask = Task {
            try await queue.send(2)
        }
        let suspendedValue = await suspendedSends.next()
        XCTAssertEqual(suspendedValue, 2)

        queue.finish()

        do {
            try await sendTask.value
            XCTFail("A send waiting for capacity must terminate on finish")
        } catch {
            XCTAssertEqual(error as? BoundedAsyncQueueError, .terminated)
        }

        var iterator = queue.stream.makeAsyncIterator()
        let acceptedValue = await iterator.next()
        let terminalValue = await iterator.next()
        XCTAssertEqual(acceptedValue, 1)
        XCTAssertNil(terminalValue)

        do {
            try await queue.send(3)
            XCTFail("A finished queue must reject future sends")
        } catch {
            XCTAssertEqual(error as? BoundedAsyncQueueError, .terminated)
        }
    }

    func testFinishWakesBlockedConsumer() async {
        let queue = BoundedAsyncQueue<Int>(capacity: 1)
        let nextStarted = expectation(description: "next started")
        let nextFinished = expectation(description: "next finished")
        let nextTask = Task { () -> Int? in
            var iterator = queue.stream.makeAsyncIterator()
            nextStarted.fulfill()
            let value = await iterator.next()
            nextFinished.fulfill()
            return value
        }
        await fulfillment(of: [nextStarted], timeout: 1)
        await Task.yield()

        queue.finish()

        await fulfillment(of: [nextFinished], timeout: 1)
        nextTask.cancel()
        let value = await nextTask.value
        XCTAssertNil(value)
    }

    func testCancellingBlockedSendDoesNotConsumeFutureCapacity() async throws {
        let suspendedSendPair = AsyncStream.makeStream(of: Int.self)
        let suspendedSendContinuation = suspendedSendPair.continuation
        let queue = BoundedAsyncQueue<Int>(
            capacity: 1,
            onSendSuspended: { value in
                suspendedSendContinuation.yield(value)
            }
        )
        var suspendedSends = suspendedSendPair.stream.makeAsyncIterator()
        try await queue.send(1)

        let sendTask = Task {
            try await queue.send(2)
        }
        let suspendedValue = await suspendedSends.next()
        XCTAssertEqual(suspendedValue, 2)

        sendTask.cancel()
        do {
            try await sendTask.value
            XCTFail("A cancelled send must not remain suspended")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        var iterator = queue.stream.makeAsyncIterator()
        let firstValue = await iterator.next()
        XCTAssertEqual(firstValue, 1)
        try await queue.send(3)
        let nextValue = await iterator.next()
        XCTAssertEqual(nextValue, 3)
    }

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

    func testFinishClosesInputBeforeWaitingForActiveAppend() async throws {
        let operations = ControlledSpeechPipelineOperations(
            waitsForAppendRelease: true
        )
        let lifecycle = SpeechPipelineLifecycle(operations: operations)

        let appendTask = Task {
            try await lifecycle.append(1)
        }
        await operations.waitUntilAppendStarts()

        let finishInvocationStarted = expectation(description: "finish invoked")
        let finishTask = Task {
            finishInvocationStarted.fulfill()
            try await lifecycle.finish()
        }
        await fulfillment(of: [finishInvocationStarted], timeout: 1)

        let finishInputObserved = expectation(description: "finish input observed")
        let finishInputObserver = Task {
            await operations.waitUntilFinishInput()
            finishInputObserved.fulfill()
        }
        await fulfillment(of: [finishInputObserved], timeout: 1)
        XCTAssertEqual(operations.events, [.append(1), .finishInput])

        operations.releaseAppend()
        let appendedValue = try await appendTask.value
        XCTAssertEqual(appendedValue, 1)
        try await finishTask.value
        await finishInputObserver.value
        XCTAssertEqual(
            operations.events,
            [.append(1), .finishInput, .finalize, .cancelResults, .awaitResults]
        )
    }

    func testTailBackpressureFailureStillCleansResources() async {
        let operations = ControlledSpeechPipelineOperations(
            drainError: .analyzerInputDropped
        )
        let lifecycle = SpeechPipelineLifecycle(operations: operations)

        let error = await capturedError {
            try await lifecycle.finish()
        }

        XCTAssertEqual(
            error as? ControlledSpeechPipelineOperations.TestError,
            .analyzerInputDropped
        )
        XCTAssertEqual(
            operations.events,
            [.drainTail, .finishInput, .cancelAnalyzer, .cancelResults, .awaitResults]
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
        case analyzerInputDropped
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
    private let waitsForAppendRelease: Bool
    private let waitsForFinalizeRelease: Bool
    private let appendStarted: AsyncStream<Void>
    private let appendStartedContinuation: AsyncStream<Void>.Continuation
    private let appendRelease: AsyncStream<Void>
    private let appendReleaseContinuation: AsyncStream<Void>.Continuation
    private let finishInputObserved: AsyncStream<Void>
    private let finishInputObservedContinuation: AsyncStream<Void>.Continuation
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
        waitsForAppendRelease: Bool = false,
        waitsForFinalizeRelease: Bool = false
    ) {
        self.drainError = drainError
        self.waitsForAppendRelease = waitsForAppendRelease
        self.waitsForFinalizeRelease = waitsForFinalizeRelease
        let appendStartedPair = AsyncStream.makeStream(of: Void.self)
        appendStarted = appendStartedPair.stream
        appendStartedContinuation = appendStartedPair.continuation
        let appendReleasePair = AsyncStream.makeStream(of: Void.self)
        appendRelease = appendReleasePair.stream
        appendReleaseContinuation = appendReleasePair.continuation
        let finishInputPair = AsyncStream.makeStream(of: Void.self)
        finishInputObserved = finishInputPair.stream
        finishInputObservedContinuation = finishInputPair.continuation
        let startedPair = AsyncStream.makeStream(of: Void.self)
        finalizeStarted = startedPair.stream
        finalizeStartedContinuation = startedPair.continuation
        let releasePair = AsyncStream.makeStream(of: Void.self)
        finalizeRelease = releasePair.stream
        finalizeReleaseContinuation = releasePair.continuation
    }

    func append(_ sample: Int) async throws -> Int {
        record(.append(sample))
        appendStartedContinuation.yield()
        if waitsForAppendRelease {
            for await _ in appendRelease {
                break
            }
        }
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
        finishInputObservedContinuation.yield()
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

    func waitUntilAppendStarts() async {
        for await _ in appendStarted {
            return
        }
    }

    func waitUntilFinishInput() async {
        for await _ in finishInputObserved {
            return
        }
    }

    func releaseAppend() {
        appendReleaseContinuation.yield()
        appendReleaseContinuation.finish()
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
