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

actor SpeechPipeline {
    private static let analyzerInputCapacity = 8

    private let analyzer: SpeechAnalyzer
    private let converter: AudioPCMConverter
    private let inputQueue: BoundedAsyncQueue<AnalyzerInput>
    private let resultsTask: Task<Void, any Error>
    private var isFinished = false

    private init(
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

        return SpeechPipeline(
            analyzer: analyzer,
            converter: AudioPCMConverter(outputFormat: audioFormat),
            inputQueue: inputQueue,
            resultsTask: resultsTask
        )
    }

    @discardableResult
    func append(_ sample: CapturedAudioSample, audibleThreshold: Float) throws -> Bool {
        guard !isFinished else {
            throw SpeechPipelineError.finished
        }
        let buffer = try converter.convert(sample.buffer)
        if buffer.frameLength > 0 {
            try yieldToAnalyzer(buffer)
        }
        return buffer.frameLength > 0
            && AudioPCMConverter.hasAudibleEnergy(buffer, threshold: audibleThreshold)
    }

    func finish() async throws {
        guard !isFinished else { return }
        isFinished = true

        let tailBuffers = try converter.finish()
        for buffer in tailBuffers where buffer.frameLength > 0 {
            try yieldToAnalyzer(buffer)
        }
        inputQueue.finish()

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            await awaitCancelledResultsTask()
            throw error
        }

        resultsTask.cancel()
        do {
            try await resultsTask.value
        } catch is CancellationError {
            return
        } catch {
            throw error
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

    private func awaitCancelledResultsTask() async {
        do {
            try await resultsTask.value
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}
