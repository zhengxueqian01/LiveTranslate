import AVFAudio
import CoreMedia
import Foundation
import Speech

struct CapturedAudioSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

enum SpeechPipelineError: LocalizedError {
    case compatibleAudioFormatUnavailable
    case analyzerInputDropped
    case finished

    var errorDescription: String? {
        switch self {
        case .compatibleAudioFormatUnavailable:
            "系统没有可用于当前语言模型的音频格式。"
        case .analyzerInputDropped:
            "语音识别处理速度不足，音频输入队列已满。"
        case .finished:
            "语音识别管线已经结束。"
        }
    }
}

private struct SpeechPipelineAppendRequest: Sendable {
    let sample: CapturedAudioSample
    let audibleThreshold: Float
}

private final class SpeechPipelineRuntime:
    SpeechPipelineLifecycleOperations,
    @unchecked Sendable
{
    typealias Sample = SpeechPipelineAppendRequest
    typealias AppendResult = Bool

    private let analyzer: SpeechAnalyzer
    private let converter: AudioPCMConverter
    private let inputQueue: BoundedAsyncQueue<AnalyzerInput>
    private let resultsTask: Task<Void, any Error>

    init(
        analyzer: SpeechAnalyzer,
        converter: AudioPCMConverter,
        inputQueue: BoundedAsyncQueue<AnalyzerInput>,
        resultsTask: Task<Void, any Error>
    ) {
        self.analyzer = analyzer
        self.converter = converter
        self.inputQueue = inputQueue
        self.resultsTask = resultsTask
    }

    func append(_ request: SpeechPipelineAppendRequest) async throws -> Bool {
        let buffer = try converter.convert(request.sample.buffer)
        if buffer.frameLength > 0 {
            try await sendToAnalyzer(buffer)
        }
        return buffer.frameLength > 0
            && AudioPCMConverter.hasAudibleEnergy(
                buffer,
                threshold: request.audibleThreshold
            )
    }

    func drainTail() throws {
        for buffer in try converter.finish() where buffer.frameLength > 0 {
            try yieldToAnalyzer(buffer)
        }
    }

    func finishInput() {
        inputQueue.finish()
    }

    func finalizeAnalyzer() async throws {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancelAnalyzer() async {
        await analyzer.cancelAndFinishNow()
    }

    func cancelResults() {
        resultsTask.cancel()
    }

    func awaitResults() async throws {
        try await resultsTask.value
    }

    private func sendToAnalyzer(_ buffer: AVAudioPCMBuffer) async throws {
        do {
            try await inputQueue.send(AnalyzerInput(buffer: buffer))
        } catch BoundedAsyncQueueError.dropped {
            throw SpeechPipelineError.analyzerInputDropped
        } catch BoundedAsyncQueueError.terminated {
            throw SpeechPipelineError.finished
        }
    }

    private func yieldToAnalyzer(_ buffer: AVAudioPCMBuffer) throws {
        do {
            try inputQueue.yield(AnalyzerInput(buffer: buffer))
        } catch BoundedAsyncQueueError.dropped {
            throw SpeechPipelineError.analyzerInputDropped
        } catch BoundedAsyncQueueError.terminated {
            throw SpeechPipelineError.finished
        }
    }
}

actor SpeechPipeline {
    private static let analyzerInputCapacity = 8

    private let lifecycle: SpeechPipelineLifecycle<SpeechPipelineRuntime>

    private init(lifecycle: SpeechPipelineLifecycle<SpeechPipelineRuntime>) {
        self.lifecycle = lifecycle
    }

    static func start(
        source: SourceLanguage,
        onText: @escaping @Sendable (String) async -> Void,
        onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }
    ) async throws -> SpeechPipeline {
        let transcriber = SpeechTranscriber(
            locale: source.speechLocale,
            preset: .progressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw SpeechPipelineError.compatibleAudioFormatUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        let inputQueue = BoundedAsyncQueue<AnalyzerInput>(
            capacity: analyzerInputCapacity
        )
        let resultsTask = Task<Void, any Error> {
            do {
                for try await result in transcriber.results {
                    await onText(String(result.text.characters))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await onFailure(error)
                throw error
            }
        }

        do {
            try await analyzer.start(inputSequence: inputQueue.stream)
        } catch {
            inputQueue.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            do {
                try await resultsTask.value
            } catch is CancellationError {
                // Expected after explicit cancellation.
            } catch {
                // The result task already delivered this through onFailure.
            }
            throw error
        }

        let runtime = SpeechPipelineRuntime(
            analyzer: analyzer,
            converter: AudioPCMConverter(outputFormat: audioFormat),
            inputQueue: inputQueue,
            resultsTask: resultsTask
        )
        return SpeechPipeline(
            lifecycle: SpeechPipelineLifecycle(operations: runtime)
        )
    }

    @discardableResult
    func append(
        _ sample: CapturedAudioSample,
        audibleThreshold: Float
    ) async throws -> Bool {
        do {
            return try await lifecycle.append(
                SpeechPipelineAppendRequest(
                    sample: sample,
                    audibleThreshold: audibleThreshold
                )
            )
        } catch SpeechPipelineLifecycleError.finished {
            throw SpeechPipelineError.finished
        }
    }

    func finish() async throws {
        try await lifecycle.finish()
    }
}
