import Foundation

enum BoundedAsyncQueueError: Error, Equatable {
    case dropped
    case terminated
}

final class BoundedAsyncQueue<Element: Sendable>: Sendable {
    let stream: AsyncStream<Element>

    private let continuation: AsyncStream<Element>.Continuation

    init(capacity: Int) {
        precondition(capacity > 0)
        let pair = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingOldest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ element: Element) throws {
        switch continuation.yield(element) {
        case .enqueued:
            return
        case .dropped:
            throw BoundedAsyncQueueError.dropped
        case .terminated:
            throw BoundedAsyncQueueError.terminated
        @unknown default:
            throw BoundedAsyncQueueError.terminated
        }
    }

    func finish() {
        continuation.finish()
    }
}

enum SpeechPipelineLifecycleError: Error, Equatable {
    case finished
}

protocol SpeechPipelineLifecycleOperations: Sendable {
    associatedtype Sample: Sendable
    associatedtype AppendResult: Sendable

    func append(_ sample: Sample) throws -> AppendResult
    func drainTail() throws
    func finishInput()
    func finalizeAnalyzer() async throws
    func cancelAnalyzer() async
    func cancelResults()
    func awaitResults() async throws
}

actor SpeechPipelineLifecycle<Operations: SpeechPipelineLifecycleOperations> {
    private let operations: Operations
    private var terminationTask: Task<Void, any Error>?

    init(operations: Operations) {
        self.operations = operations
    }

    func append(_ sample: Operations.Sample) throws -> Operations.AppendResult {
        guard terminationTask == nil else {
            throw SpeechPipelineLifecycleError.finished
        }
        return try operations.append(sample)
    }

    func finish() async throws {
        let task: Task<Void, any Error>
        if let terminationTask {
            task = terminationTask
        } else {
            let operations = self.operations
            let createdTask = Task<Void, any Error> {
                try await Self.terminate(operations)
            }
            terminationTask = createdTask
            task = createdTask
        }
        try await task.value
    }

    private static func terminate(_ operations: Operations) async throws {
        var primaryError: (any Error)?

        do {
            try operations.drainTail()
        } catch {
            primaryError = error
        }

        operations.finishInput()

        if primaryError == nil {
            do {
                try await operations.finalizeAnalyzer()
            } catch {
                primaryError = error
            }
        }

        if primaryError != nil {
            await operations.cancelAnalyzer()
        }

        operations.cancelResults()
        do {
            try await operations.awaitResults()
        } catch is CancellationError {
            // Expected after explicit result-task cancellation.
        } catch {
            if primaryError == nil {
                primaryError = error
                await operations.cancelAnalyzer()
            }
        }

        if let primaryError {
            throw primaryError
        }
    }
}

final class BroadcastCaptionCoordinator: @unchecked Sendable {
    private enum Lifecycle {
        case initialized
        case active
        case terminal
    }

    private let store: any CaptionStoreProtocol
    private let lock = NSLock()
    private var lifecycle = Lifecycle.initialized
    private var hasSilenceWarning = false

    init(store: any CaptionStoreProtocol) {
        self.store = store
    }

    func begin() throws {
        try lock.withLock {
            guard lifecycle != .terminal else { return }
            try write(phase: .broadcasting, errorMessage: nil)
            lifecycle = .active
        }
    }

    func markRecognizing() throws {
        try lock.withLock {
            guard lifecycle == .active else { return }
            let previous = try store.load()
            try write(
                phase: .recognizing,
                errorMessage: previous?.errorMessage
            )
        }
    }

    func updateText(_ text: String) throws {
        try lock.withLock {
            guard lifecycle == .active else { return }
            let previous = try store.load()
            try write(
                sourceText: text,
                phase: .recognizing,
                errorMessage: hasSilenceWarning ? previous?.errorMessage : nil
            )
        }
    }

    func reportSilence(message: String) throws {
        try lock.withLock {
            guard lifecycle == .active else { return }
            try write(phase: .recognizing, errorMessage: message)
            hasSilenceWarning = true
        }
    }

    func clearSilenceWarning() throws {
        try lock.withLock {
            guard lifecycle == .active, hasSilenceWarning else { return }
            try write(phase: .recognizing, errorMessage: nil)
            hasSilenceWarning = false
        }
    }

    func fail(message: String) throws {
        try lock.withLock {
            guard lifecycle != .terminal else { return }
            try write(phase: .failed, errorMessage: message)
            lifecycle = .terminal
            hasSilenceWarning = false
        }
    }

    func stop() throws {
        try lock.withLock {
            guard lifecycle != .terminal else { return }
            try write(phase: .stopped, errorMessage: nil)
            lifecycle = .terminal
            hasSilenceWarning = false
        }
    }

    private func write(
        sourceText: String? = nil,
        phase: SessionPhase,
        errorMessage: String?
    ) throws {
        let previous = try store.load()
        try store.save(
            CaptionSnapshot(
                revision: (previous?.revision ?? 0) + 1,
                sourceText: sourceText ?? previous?.sourceText ?? "",
                translatedText: previous?.translatedText ?? "",
                phase: phase,
                errorMessage: errorMessage,
                updatedAt: Date()
            )
        )
    }
}

struct SilenceMonitorState: Sendable {
    private var lastAudibleAt: Duration?
    private var isPaused = false
    private var didReportWarning = false

    mutating func start(at now: Duration) {
        lastAudibleAt = now
        isPaused = false
        didReportWarning = false
    }

    @discardableResult
    mutating func markAudible(at now: Duration) -> Bool {
        let shouldClearWarning = didReportWarning
        lastAudibleAt = now
        didReportWarning = false
        return shouldClearWarning
    }

    mutating func pause() {
        isPaused = true
    }

    @discardableResult
    mutating func resume(at now: Duration) -> Bool {
        let shouldClearWarning = didReportWarning
        lastAudibleAt = now
        isPaused = false
        didReportWarning = false
        return shouldClearWarning
    }

    mutating func takeWarningIfDue(at now: Duration, after threshold: Duration) -> Bool {
        guard !isPaused,
              !didReportWarning,
              let lastAudibleAt,
              now - lastAudibleAt >= threshold else {
            return false
        }
        didReportWarning = true
        return true
    }
}
