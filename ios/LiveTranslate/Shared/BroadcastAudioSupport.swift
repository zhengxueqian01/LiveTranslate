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
