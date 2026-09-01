import AVFAudio
import CoreMedia
import Foundation
import Speech

enum SpeechPipelineError: LocalizedError {
    case compatibleAudioFormatUnavailable
    case finished

    var errorDescription: String? {
        switch self {
        case .compatibleAudioFormatUnavailable:
            "系统没有可用于当前语言模型的音频格式。"
        case .finished:
            "语音识别管线已经结束。"
        }
    }
}

final class SpeechPipeline: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let converter: AudioPCMConverter
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let resultsTask: Task<Void, any Error>
    private let stateLock = NSLock()
    private var isFinished = false

    private init(
        analyzer: SpeechAnalyzer,
        converter: AudioPCMConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        resultsTask: Task<Void, any Error>
    ) {
        self.analyzer = analyzer
        self.converter = converter
        self.continuation = continuation
        self.resultsTask = resultsTask
    }

    static func start(
        source: SourceLanguage,
        onText: @escaping @Sendable (String) async -> Void
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
        let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let resultsTask = Task<Void, any Error> {
            for try await result in transcriber.results {
                await onText(String(result.text.characters))
            }
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            continuation.finish()
            resultsTask.cancel()
            throw error
        }

        return SpeechPipeline(
            analyzer: analyzer,
            converter: AudioPCMConverter(outputFormat: audioFormat),
            continuation: continuation,
            resultsTask: resultsTask
        )
    }

    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard stateLock.withLock({ !isFinished }) else {
            throw SpeechPipelineError.finished
        }
        let buffer = try converter.convert(sampleBuffer)
        continuation.yield(AnalyzerInput(buffer: buffer))
        return buffer
    }

    func finish() async {
        let shouldFinish = stateLock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        guard shouldFinish else { return }

        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        resultsTask.cancel()
        _ = try? await resultsTask.value
    }
}
