import Foundation

protocol CaptionTranslating: Sendable {
    func translate(_ text: String) async throws -> String
}

final class BroadcastCaptionCoordinator: @unchecked Sendable {
    private enum Lifecycle {
        case initialized
        case active
        case terminal
    }

    private struct PendingTranslation {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let translator: (any CaptionTranslating)?
    private let store: any CaptionStoreProtocol
    private let onFailure: @Sendable (any Error) async -> Void
    private let lock = NSLock()
    private var lifecycle = Lifecycle.initialized
    private var hasSilenceWarning = false
    private var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)
    private var generation: UInt64 = 0
    private var pendingTranslation: PendingTranslation?
    private var terminalError: (any Error)?

    init(store: any CaptionStoreProtocol) {
        translator = nil
        self.store = store
        onFailure = { _ in }
    }

    init(
        translator: any CaptionTranslating,
        store: any CaptionStoreProtocol,
        onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }
    ) {
        self.translator = translator
        self.store = store
        self.onFailure = onFailure
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

    func receiveRecognizedText(
        _ text: String,
        isFinal: Bool,
        timestampMilliseconds: UInt64
    ) async {
        let failure = lock.withLock { () -> (any Error)? in
            guard lifecycle != .terminal else { return nil }

            do {
                guard let update = segmenter.ingest(
                    text: text,
                    isFinal: isFinal,
                    timestampMilliseconds: timestampMilliseconds
                ) else {
                    return nil
                }

                if lifecycle == .initialized {
                    lifecycle = .active
                }

                let previous = try store.load()
                let sourceChanged = previous?.sourceText != update.displayText
                if sourceChanged {
                    advanceGenerationLocked()
                    try write(
                        sourceText: update.displayText,
                        translatedText: "",
                        phase: .recognizing,
                        errorMessage: hasSilenceWarning ? previous?.errorMessage : nil
                    )
                }

                guard let candidate = update.translationCandidate,
                      let translator else {
                    return nil
                }

                if !sourceChanged {
                    advanceGenerationLocked()
                }
                let candidateGeneration = generation
                let task = Task { [weak self, translator, sourceText = candidate.text] in
                    do {
                        let translatedText = try await translator.translate(sourceText)
                        guard let self else { return }
                        let failure = self.completeTranslation(
                            translatedText,
                            generation: candidateGeneration
                        )
                        self.removePendingTranslation(generation: candidateGeneration)
                        if let failure {
                            await self.onFailure(failure)
                        }
                    } catch {
                        guard let self else { return }
                        let failure = self.completeTranslationFailure(
                            error,
                            generation: candidateGeneration
                        )
                        self.removePendingTranslation(generation: candidateGeneration)
                        if let failure {
                            await self.onFailure(failure)
                        }
                    }
                }
                pendingTranslation = PendingTranslation(
                    generation: candidateGeneration,
                    task: task
                )
                return nil
            } catch {
                lifecycle = .terminal
                terminalError = error
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
                return error
            }
        }

        if let failure {
            await onFailure(failure)
        }
    }

    func flushPendingTranslations() async throws {
        let currentTask = lock.withLock { pendingTranslation?.task }
        await currentTask?.value

        if let terminalError = lock.withLock({ terminalError }) {
            throw terminalError
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
            do {
                try write(phase: .failed, errorMessage: message)
                lifecycle = .terminal
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
            } catch {
                lifecycle = .terminal
                terminalError = error
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
                throw error
            }
        }
    }

    func stop() throws {
        try lock.withLock {
            guard lifecycle != .terminal else { return }
            do {
                try write(phase: .stopped, errorMessage: nil)
                lifecycle = .terminal
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
            } catch {
                lifecycle = .terminal
                terminalError = error
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
                throw error
            }
        }
    }

    private func advanceGenerationLocked() {
        generation &+= 1
        cancelPendingTranslationLocked()
    }

    private func cancelPendingTranslationLocked() {
        let task = pendingTranslation?.task
        pendingTranslation = nil
        task?.cancel()
    }

    private func removePendingTranslation(generation candidateGeneration: UInt64) {
        lock.withLock {
            guard pendingTranslation?.generation == candidateGeneration else {
                return
            }
            pendingTranslation = nil
        }
    }

    private func completeTranslation(
        _ translatedText: String,
        generation candidateGeneration: UInt64
    ) -> (any Error)? {
        lock.withLock {
            guard lifecycle != .terminal,
                  candidateGeneration == generation else {
                return nil
            }
            do {
                let previous = try store.load()
                try write(
                    translatedText: translatedText,
                    phase: .recognizing,
                    errorMessage: hasSilenceWarning ? previous?.errorMessage : nil
                )
                return nil
            } catch {
                lifecycle = .terminal
                terminalError = error
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
                return error
            }
        }
    }

    private func completeTranslationFailure(
        _ error: any Error,
        generation candidateGeneration: UInt64
    ) -> (any Error)? {
        lock.withLock {
            guard lifecycle != .terminal,
                  candidateGeneration == generation else {
                return nil
            }
            do {
                try write(
                    phase: .failed,
                    errorMessage: error.localizedDescription
                )
                lifecycle = .terminal
                terminalError = error
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
                return error
            } catch {
                lifecycle = .terminal
                terminalError = error
                hasSilenceWarning = false
                cancelPendingTranslationLocked()
                return error
            }
        }
    }

    private func write(
        sourceText: String? = nil,
        translatedText: String? = nil,
        phase: SessionPhase,
        errorMessage: String?
    ) throws {
        let previous = try store.load()
        try store.save(
            CaptionSnapshot(
                revision: (previous?.revision ?? 0) + 1,
                sourceText: sourceText ?? previous?.sourceText ?? "",
                translatedText: translatedText ?? previous?.translatedText ?? "",
                phase: phase,
                errorMessage: errorMessage,
                updatedAt: Date()
            )
        )
    }
}
