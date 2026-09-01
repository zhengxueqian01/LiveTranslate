actor AsyncSerialExecutor {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let predecessor = tail
        generation &+= 1
        let operationGeneration = generation
        let operationTask = Task<Result<Value, any Error>, Never> {
            await predecessor?.value
            do {
                try Task.checkCancellation()
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        tail = Task {
            _ = await operationTask.value
        }

        let result = await withTaskCancellationHandler {
            await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
        if operationGeneration == generation {
            tail = nil
        }
        return try result.get()
    }
}
