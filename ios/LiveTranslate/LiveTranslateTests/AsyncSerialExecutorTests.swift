import XCTest
@testable import LiveTranslate

final class AsyncSerialExecutorTests: XCTestCase {
    func testCancelledQueuedOperationNeverStartsAfterPredecessorFinishes() async throws {
        let executor = AsyncSerialExecutor()
        let events = AsyncEventRecorder()
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()

        let firstTask = Task {
            try await executor.run {
                await events.append("first-started")
                await firstStarted.open()
                await releaseFirst.wait()
                await events.append("first-finished")
                return 1
            }
        }
        await firstStarted.wait()

        let secondInvocationStarted = AsyncTestGate()
        let secondTask = Task {
            await secondInvocationStarted.open()
            return try await executor.run {
                await events.append("second-started")
                return 2
            }
        }
        await secondInvocationStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        secondTask.cancel()

        let thirdInvocationStarted = AsyncTestGate()
        let thirdTask = Task {
            await thirdInvocationStarted.open()
            return try await executor.run {
                await events.append("third-started")
                return 3
            }
        }
        await thirdInvocationStarted.wait()
        try await Task.sleep(for: .milliseconds(50))

        let eventsBeforeRelease = await events.values
        XCTAssertEqual(eventsBeforeRelease, ["first-started"])

        await releaseFirst.open()
        let firstValue = try await firstTask.value
        XCTAssertEqual(firstValue, 1)

        do {
            _ = try await secondTask.value
            XCTFail("Expected the cancelled queued operation to throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let thirdValue = try await thirdTask.value
        XCTAssertEqual(thirdValue, 3)
        let finalEvents = await events.values
        XCTAssertEqual(
            finalEvents,
            ["first-started", "first-finished", "third-started"]
        )
    }

    func testStartedOperationIgnoringCancellationStillBlocksNextUntilItReturns() async throws {
        let executor = AsyncSerialExecutor()
        let events = AsyncEventRecorder()
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()

        let firstTask = Task {
            try await executor.run {
                await events.append("first-started")
                await firstStarted.open()
                await releaseFirst.wait()
                await events.append("first-cancelled-\(Task.isCancelled)")
                await events.append("first-finished")
                return 1
            }
        }
        await firstStarted.wait()
        firstTask.cancel()

        let secondInvocationStarted = AsyncTestGate()
        let secondTask = Task {
            await secondInvocationStarted.open()
            return try await executor.run {
                await events.append("second-started")
                return 2
            }
        }
        await secondInvocationStarted.wait()
        try await Task.sleep(for: .milliseconds(50))

        let eventsBeforeRelease = await events.values
        XCTAssertEqual(eventsBeforeRelease, ["first-started"])

        await releaseFirst.open()
        let firstValue = try await firstTask.value
        let secondValue = try await secondTask.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        let finalEvents = await events.values
        XCTAssertEqual(
            finalEvents,
            [
                "first-started",
                "first-cancelled-true",
                "first-finished",
                "second-started",
            ]
        )
    }
}

private actor AsyncEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
