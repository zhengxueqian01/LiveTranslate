import Foundation

enum BoundedAsyncQueueError: Error, Equatable {
    case dropped
    case terminated
}

final class BoundedAsyncQueue<Value: Sendable>: @unchecked Sendable {
    struct Stream: AsyncSequence, Sendable {
        typealias Element = Value

        fileprivate let queue: BoundedAsyncQueue<Value>

        func makeAsyncIterator() -> Iterator {
            Iterator(queue: queue)
        }
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate let queue: BoundedAsyncQueue<Value>

        mutating func next() async -> Value? {
            await queue.next()
        }
    }

    var stream: Stream {
        Stream(queue: self)
    }

    private struct PendingSender {
        let id: UUID
        let value: Value
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingReceiver {
        let id: UUID
        let continuation: CheckedContinuation<Value?, Never>
    }

    private enum NextAction {
        case suspend
        case resume(Value?)
    }

    private let capacity: Int
    private let lock = NSLock()
    private var bufferedValues: [Value] = []
    private var pendingSenders: [PendingSender] = []
    private var pendingReceivers: [PendingReceiver] = []
    private var isFinished = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func yield(_ value: Value) throws {
        var receiver: CheckedContinuation<Value?, Never>?
        try lock.withLock {
            guard !isFinished else {
                throw BoundedAsyncQueueError.terminated
            }
            if !pendingReceivers.isEmpty {
                receiver = pendingReceivers.removeFirst().continuation
            } else if bufferedValues.count < capacity && pendingSenders.isEmpty {
                bufferedValues.append(value)
            } else {
                throw BoundedAsyncQueueError.dropped
            }
        }
        receiver?.resume(returning: value)
    }

    func send(_ value: Value) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var receiver: CheckedContinuation<Value?, Never>?
                var immediateError: (any Error)?
                var didAccept = false
                lock.withLock {
                    if Task.isCancelled {
                        immediateError = CancellationError()
                    } else if isFinished {
                        immediateError = BoundedAsyncQueueError.terminated
                    } else if !pendingReceivers.isEmpty {
                        receiver = pendingReceivers.removeFirst().continuation
                        didAccept = true
                    } else if bufferedValues.count < capacity && pendingSenders.isEmpty {
                        bufferedValues.append(value)
                        didAccept = true
                    } else {
                        pendingSenders.append(
                            PendingSender(
                                id: id,
                                value: value,
                                continuation: continuation
                            )
                        )
                    }
                }

                if let immediateError {
                    continuation.resume(throwing: immediateError)
                } else if didAccept {
                    receiver?.resume(returning: value)
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelSender(id: id)
        }
    }

    func finish() {
        let waiters = lock.withLock {
            guard !isFinished else {
                return (senders: [PendingSender](), receivers: [PendingReceiver]())
            }
            isFinished = true
            let waiters = (senders: pendingSenders, receivers: pendingReceivers)
            pendingSenders.removeAll()
            pendingReceivers.removeAll()
            return waiters
        }
        waiters.senders.forEach {
            $0.continuation.resume(throwing: BoundedAsyncQueueError.terminated)
        }
        waiters.receivers.forEach {
            $0.continuation.resume(returning: nil)
        }
    }

    private func next() async -> Value? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var sender: PendingSender?
                let action = lock.withLock { () -> NextAction in
                    if Task.isCancelled {
                        return .resume(nil)
                    }
                    if !bufferedValues.isEmpty {
                        let value = bufferedValues.removeFirst()
                        if !pendingSenders.isEmpty {
                            let pendingSender = pendingSenders.removeFirst()
                            sender = pendingSender
                            bufferedValues.append(pendingSender.value)
                        }
                        return .resume(value)
                    }
                    if !pendingSenders.isEmpty {
                        let pendingSender = pendingSenders.removeFirst()
                        sender = pendingSender
                        return .resume(pendingSender.value)
                    }
                    if isFinished {
                        return .resume(nil)
                    }
                    pendingReceivers.append(
                        PendingReceiver(id: id, continuation: continuation)
                    )
                    return .suspend
                }

                sender?.continuation.resume()
                if case let .resume(value) = action {
                    continuation.resume(returning: value)
                }
            }
        } onCancel: {
            self.cancelReceiver(id: id)
        }
    }

    private func cancelSender(id: UUID) {
        let continuation = lock.withLock {
            guard let index = pendingSenders.firstIndex(where: { $0.id == id }) else {
                return nil as CheckedContinuation<Void, any Error>?
            }
            return pendingSenders.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelReceiver(id: UUID) {
        let continuation = lock.withLock {
            guard let index = pendingReceivers.firstIndex(where: { $0.id == id }) else {
                return nil as CheckedContinuation<Value?, Never>?
            }
            return pendingReceivers.remove(at: index).continuation
        }
        continuation?.resume(returning: nil)
    }
}

enum SpeechPipelineLifecycleError: Error, Equatable {
    case finished
}

protocol SpeechPipelineLifecycleOperations: Sendable {
    associatedtype Sample: Sendable
    associatedtype AppendResult: Sendable

    func append(_ sample: Sample) async throws -> AppendResult
    func drainTail() async throws
    func finishInput()
    func finalizeAnalyzer() async throws
    func cancelAnalyzer() async
    func cancelResults()
    func awaitResults() async throws
}

actor SpeechPipelineLifecycle<Operations: SpeechPipelineLifecycleOperations> {
    private let operations: Operations
    private let serialExecutor = AsyncSerialExecutor()
    private var terminationTask: Task<Void, any Error>?

    init(operations: Operations) {
        self.operations = operations
    }

    func append(_ sample: Operations.Sample) async throws -> Operations.AppendResult {
        guard terminationTask == nil else {
            throw SpeechPipelineLifecycleError.finished
        }
        let operations = self.operations
        return try await serialExecutor.run {
            try await operations.append(sample)
        }
    }

    func finish() async throws {
        let task: Task<Void, any Error>
        if let terminationTask {
            task = terminationTask
        } else {
            let operations = self.operations
            let serialExecutor = self.serialExecutor
            let createdTask = Task<Void, any Error> {
                try await serialExecutor.run {
                    try await Self.terminate(operations)
                }
            }
            terminationTask = createdTask
            task = createdTask
        }
        try await task.value
    }

    private static func terminate(_ operations: Operations) async throws {
        var primaryError: (any Error)?

        do {
            try await operations.drainTail()
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
