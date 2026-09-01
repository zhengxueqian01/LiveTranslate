import XCTest
@testable import LiveTranslate

final class AsyncSerialExecutorTests: XCTestCase {
    func testCancelledCallerDoesNotReleaseNextOperationBeforeCurrentOperationReturns() async throws {
        let executor = AsyncSerialExecutor()
        let events = AsyncEventRecorder()
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()
        let secondInvocationStarted = AsyncTestGate()

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
        firstTask.cancel()

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
            ["first-started", "first-finished", "second-started"]
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
