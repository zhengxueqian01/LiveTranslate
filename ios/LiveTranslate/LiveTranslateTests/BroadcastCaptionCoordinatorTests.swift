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
        await translator.waitUntilRequested("pending")

        let pendingSnapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(pendingSnapshot.sourceText, "pending")
        XCTAssertEqual(pendingSnapshot.translatedText, "")

        await translator.succeed("pending", with: "待处理")
        try await coordinator.flushPendingTranslations()
    }

    func testCurrentTranslationFailureIsTerminalAndLateSuccessCannotRecover() async throws {
        let translator = ControlledTranslator()
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
        await translator.waitUntilRequested("older")
        await coordinator.receiveRecognizedText(
            "newer",
            isFinal: true,
            timestampMilliseconds: 1
        )
        await translator.waitUntilRequested("newer")

        await translator.fail("newer", with: .translationFailed)
        await translator.waitUntilCompleted("newer")
        await translator.succeed("older", with: "较旧译文")
        _ = await capturedError {
            try await coordinator.flushPendingTranslations()
        }

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.sourceText, "newer")
        XCTAssertEqual(snapshot.translatedText, "")
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.errorMessage, "模拟翻译失败")
    }

    func testFinalDuplicateOfLastPartialStillProducesTranslation() async throws {
        let translator = ControlledTranslator()
        let store = InMemoryCaptionStore()
        let coordinator = BroadcastCaptionCoordinator(
            translator: translator,
            store: store
        )

        await coordinator.receiveRecognizedText(
            "last",
            isFinal: false,
            timestampMilliseconds: 0
        )
        await coordinator.receiveRecognizedText(
            "last",
            isFinal: true,
            timestampMilliseconds: 100
        )
        await translator.waitUntilRequested("last")
        await translator.succeed("last", with: "最后")
        try await coordinator.flushPendingTranslations()

        XCTAssertEqual(try store.load()?.translatedText, "最后")
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
        await translator.waitUntilRequested("finish")
        let finishTask = Task {
            try await coordinator.flushPendingTranslations()
            try coordinator.stop()
        }
        await Task.yield()

        XCTAssertEqual(try store.load()?.phase, .recognizing)

        await translator.succeed("finish", with: "完成")
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
        await translator.waitUntilRequested("hello")
        await translator.succeed("hello", with: "你好")
        try await coordinator.flushPendingTranslations()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.translatedText, "你好")
        XCTAssertEqual(snapshot.errorMessage, "来源静音")
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

private actor ControlledTranslator: CaptionTranslating {
    private var pending: [String: CheckedContinuation<String, any Error>] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var completed: Set<String> = []
    private var completionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func translate(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending[text] = continuation
            let waiters = requestWaiters.removeValue(forKey: text) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested(_ text: String) async {
        if pending[text] != nil {
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters[text, default: []].append(continuation)
        }
    }

    func succeed(_ text: String, with translation: String) {
        resolve(text, with: .success(translation))
    }

    func fail(_ text: String, with error: TranslationTestError) {
        resolve(text, with: .failure(error))
    }

    func waitUntilCompleted(_ text: String) async {
        if completed.contains(text) {
            return
        }
        await withCheckedContinuation { continuation in
            completionWaiters[text, default: []].append(continuation)
        }
    }

    private func resolve(
        _ text: String,
        with result: Result<String, any Error>
    ) {
        guard let continuation = pending.removeValue(forKey: text) else {
            return
        }
        continuation.resume(with: result)
        completed.insert(text)
        let waiters = completionWaiters.removeValue(forKey: text) ?? []
        waiters.forEach { $0.resume() }
    }
}

private enum TranslationTestError: LocalizedError, Sendable {
    case translationFailed

    var errorDescription: String? {
        "模拟翻译失败"
    }
}
