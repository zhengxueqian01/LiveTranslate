import XCTest
@testable import LiveTranslate

final class BroadcastCaptionCoordinatorTests: XCTestCase {
    func testStaleTranslationCannotOverwriteNewerCaption() async throws {
        let translator = DelayedFakeTranslator(
            delays: ["first": 200_000_000, "second": 10_000_000]
        )
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "first",
            isFinal: true,
            timestampMilliseconds: 0
        )
        await coordinator.receiveRecognizedText(
            "second",
            isFinal: true,
            timestampMilliseconds: 1
        )
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(try store.load()?.sourceText, "second")
        XCTAssertEqual(try store.load()?.translatedText, "译文:second")
    }

    func testSourceTextIsSavedBeforeTranslationCompletes() async throws {
        let translator = ControlledTranslator()
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "pending",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let request = await translator.waitForRequest("pending", occurrence: 1)

        let pendingSnapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(pendingSnapshot.sourceText, "pending")
        XCTAssertEqual(pendingSnapshot.translatedText, "")

        translator.succeed(request, with: "待处理")
        try await coordinator.flushPendingTranslations()
    }

    func testNewSourceImmediatelyClearsPreviousTranslationAndPreservesWarning() async throws {
        let translator = ControlledTranslator()
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )
        try coordinator.begin()

        await coordinator.receiveRecognizedText(
            "first",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let firstRequest = await translator.waitForRequest("first", occurrence: 1)
        translator.succeed(firstRequest, with: "第一译文")
        try await coordinator.flushPendingTranslations()
        try coordinator.reportSilence(message: "来源静音")

        await coordinator.receiveRecognizedText(
            "second",
            isFinal: false,
            timestampMilliseconds: 100
        )

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "second")
        XCTAssertEqual(snapshot.translatedText, "")
        XCTAssertEqual(snapshot.phase, .recognizing)
        XCTAssertEqual(snapshot.errorMessage, "来源静音")
    }

    func testOlderFailureIsCancelledAndCannotTerminateNewGeneration() async throws {
        let translator = ControlledTranslator(honorsCancellation: false)
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "older",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let olderRequest = await translator.waitForRequest("older", occurrence: 1)
        await coordinator.receiveRecognizedText(
            "newer",
            isFinal: true,
            timestampMilliseconds: 1
        )
        let newerRequest = await translator.waitForRequest("newer", occurrence: 1)

        XCTAssertTrue(translator.wasCancelled(olderRequest))

        translator.fail(olderRequest, with: .translationFailed)
        await translator.waitUntilReturned(olderRequest)
        translator.succeed(newerRequest, with: "较新译文")
        try await coordinator.flushPendingTranslations()
        await Task.yield()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "newer")
        XCTAssertEqual(snapshot.translatedText, "较新译文")
        XCTAssertEqual(snapshot.phase, .recognizing)
        XCTAssertNil(snapshot.errorMessage)
    }

    func testFinalReplacesPendingPartialCandidateAndFlushWaitsForFinal() async throws {
        let translator = ControlledTranslator(honorsCancellation: false)
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "same",
            isFinal: false,
            timestampMilliseconds: 0
        )
        await coordinator.receiveRecognizedText(
            "same text",
            isFinal: false,
            timestampMilliseconds: 800
        )
        let partialRequest = await translator.waitForRequest(
            "same text",
            occurrence: 1
        )
        await coordinator.receiveRecognizedText(
            "same text",
            isFinal: true,
            timestampMilliseconds: 900
        )

        let finalRequest = await translator.waitForRequest(
            "same text",
            occurrence: 2,
            timeout: .milliseconds(250)
        )
        XCTAssertNotNil(finalRequest)
        guard let finalRequest else {
            translator.succeed(partialRequest, with: "旧 partial 译文")
            try? await coordinator.flushPendingTranslations()
            return
        }
        XCTAssertEqual(translator.requestCount(for: "same text"), 2)
        XCTAssertTrue(translator.wasCancelled(partialRequest))

        let finishTask = Task {
            try await coordinator.flushPendingTranslations()
            try coordinator.stop()
        }
        await Task.yield()
        XCTAssertEqual(try store.load()?.phase, .recognizing)

        translator.succeed(finalRequest, with: "最终译文")
        try await finishTask.value
        translator.fail(partialRequest, with: .translationFailed)
        await translator.waitUntilReturned(partialRequest)
        await Task.yield()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.translatedText, "最终译文")
        XCTAssertEqual(snapshot.phase, .stopped)
    }

    func testFlushWaitsForFinalTranslationBeforeStop() async throws {
        let translator = ControlledTranslator()
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "finish",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let request = await translator.waitForRequest("finish", occurrence: 1)
        let finishTask = Task {
            try await coordinator.flushPendingTranslations()
            try coordinator.stop()
        }
        await Task.yield()

        XCTAssertEqual(try store.load()?.phase, .recognizing)

        translator.succeed(request, with: "完成")
        try await finishTask.value
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.translatedText, "完成")
        XCTAssertEqual(snapshot.phase, .stopped)
    }

    func testTranslationPreservesSilenceWarning() async throws {
        let translator = ControlledTranslator()
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )
        try coordinator.begin()
        try coordinator.reportSilence(message: "来源静音")

        await coordinator.receiveRecognizedText(
            "hello",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let request = await translator.waitForRequest("hello", occurrence: 1)
        translator.succeed(request, with: "你好")
        try await coordinator.flushPendingTranslations()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.translatedText, "你好")
        XCTAssertEqual(snapshot.errorMessage, "来源静音")
    }

    func testStopCancelsAndDetachesPendingTranslationBeforeLateSuccess() async throws {
        let translator = ControlledTranslator(honorsCancellation: false)
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "pending stop",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let request = await translator.waitForRequest("pending stop", occurrence: 1)
        try coordinator.stop()

        XCTAssertTrue(translator.wasCancelled(request))
        let flushFinished = expectation(description: "stop detaches pending translation")
        let flushTask = Task {
            try? await coordinator.flushPendingTranslations()
            flushFinished.fulfill()
        }
        await fulfillment(of: [flushFinished], timeout: 0.05)

        translator.succeed(request, with: "迟到成功")
        await translator.waitUntilReturned(request)
        await flushTask.value
        await Task.yield()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "pending stop")
        XCTAssertEqual(snapshot.translatedText, "")
        XCTAssertEqual(snapshot.phase, .stopped)
    }

    func testFailCancelsAndDetachesPendingTranslationBeforeLateFailure() async throws {
        let translator = ControlledTranslator(honorsCancellation: false)
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "pending fail",
            isFinal: true,
            timestampMilliseconds: 0
        )
        let request = await translator.waitForRequest("pending fail", occurrence: 1)
        try coordinator.fail(message: "外部失败")

        XCTAssertTrue(translator.wasCancelled(request))
        let flushFinished = expectation(description: "fail detaches pending translation")
        let flushTask = Task {
            try? await coordinator.flushPendingTranslations()
            flushFinished.fulfill()
        }
        await fulfillment(of: [flushFinished], timeout: 0.05)

        translator.fail(request, with: .translationFailed)
        await translator.waitUntilReturned(request)
        await flushTask.value
        await Task.yield()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "pending fail")
        XCTAssertEqual(snapshot.translatedText, "")
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.errorMessage, "外部失败")
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

private struct DelayedFakeTranslator: CaptionTranslating {
    let delays: [String: UInt64]

    func translate(_ text: String) async throws -> String {
        try await Task.sleep(nanoseconds: delays[text, default: 0])
        return "译文:\(text)"
    }
}

private final class ControlledTranslator: CaptionTranslating, @unchecked Sendable {
    private struct RequestWaiter {
        let text: String
        let occurrence: Int
        let continuation: CheckedContinuation<Int, Never>
    }

    private let honorsCancellation: Bool
    private let lock = NSLock()
    private var nextRequestID = 1
    private var requests: [(id: Int, text: String)] = []
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var returned: Set<Int> = []
    private var requestWaiters: [RequestWaiter] = []
    private var returnWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    func translate(_ text: String) async throws -> String {
        let requestID = lock.withLock {
            defer { nextRequestID += 1 }
            return nextRequestID
        }
        defer { markReturned(requestID) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (shouldCancel, readyWaiters) = lock.withLock {
                    requests.append((requestID, text))
                    let shouldCancel = honorsCancellation && cancelled.contains(requestID)
                    if !shouldCancel {
                        pending[requestID] = continuation
                    }
                    let readyWaiters = takeReadyRequestWaitersLocked()
                    return (shouldCancel, readyWaiters)
                }
                readyWaiters.forEach { waiter in
                    waiter.continuation.resume(
                        returning: resolvedRequestID(
                            for: waiter.text,
                            occurrence: waiter.occurrence
                        )
                    )
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel(requestID)
        }
    }

    func waitForRequest(_ text: String, occurrence: Int) async -> Int {
        return await withCheckedContinuation { continuation in
            let requestID = lock.withLock { () -> Int? in
                if let requestID = requestIDLocked(for: text, occurrence: occurrence) {
                    return requestID
                }
                requestWaiters.append(
                    RequestWaiter(
                        text: text,
                        occurrence: occurrence,
                        continuation: continuation
                    )
                )
                return nil
            }
            if let requestID {
                continuation.resume(returning: requestID)
            }
        }
    }

    func waitForRequest(
        _ text: String,
        occurrence: Int,
        timeout: Duration
    ) async -> Int? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let requestID = lock.withLock({
                requestIDLocked(for: text, occurrence: occurrence)
            }) {
                return requestID
            }
            await Task.yield()
        } while clock.now < deadline

        return lock.withLock {
            requestIDLocked(for: text, occurrence: occurrence)
        }
    }

    func requestCount(for text: String) -> Int {
        lock.withLock { requests.count(where: { $0.text == text }) }
    }

    func wasCancelled(_ requestID: Int) -> Bool {
        lock.withLock { cancelled.contains(requestID) }
    }

    func succeed(_ requestID: Int, with translation: String) {
        resolve(requestID, with: .success(translation))
    }

    func fail(_ requestID: Int, with error: TranslationTestError) {
        resolve(requestID, with: .failure(error))
    }

    func waitUntilReturned(_ requestID: Int) async {
        await withCheckedContinuation { continuation in
            let didReturn = lock.withLock { () -> Bool in
                guard !returned.contains(requestID) else { return true }
                returnWaiters[requestID, default: []].append(continuation)
                return false
            }
            if didReturn {
                continuation.resume()
            }
        }
    }

    private func cancel(_ requestID: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            cancelled.insert(requestID)
            guard honorsCancellation else { return nil }
            return pending.removeValue(forKey: requestID)
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func resolve(
        _ requestID: Int,
        with result: Result<String, any Error>
    ) {
        let continuation = lock.withLock {
            pending.removeValue(forKey: requestID)
        }
        continuation?.resume(with: result)
    }

    private func markReturned(_ requestID: Int) {
        let waiters = lock.withLock {
            returned.insert(requestID)
            return returnWaiters.removeValue(forKey: requestID) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    private func takeReadyRequestWaitersLocked() -> [RequestWaiter] {
        let ready = requestWaiters.filter {
            requestIDLocked(for: $0.text, occurrence: $0.occurrence) != nil
        }
        requestWaiters.removeAll { waiter in
            ready.contains { readyWaiter in
                readyWaiter.text == waiter.text
                    && readyWaiter.occurrence == waiter.occurrence
            }
        }
        return ready
    }

    private func resolvedRequestID(for text: String, occurrence: Int) -> Int {
        lock.withLock {
            requestIDLocked(for: text, occurrence: occurrence)!
        }
    }

    private func requestIDLocked(for text: String, occurrence: Int) -> Int? {
        let matchingRequests = requests.filter { $0.text == text }
        guard occurrence > 0, matchingRequests.count >= occurrence else {
            return nil
        }
        return matchingRequests[occurrence - 1].id
    }
}

private enum TranslationTestError: LocalizedError, Sendable {
    case translationFailed

    var errorDescription: String? {
        "模拟翻译失败"
    }
}
