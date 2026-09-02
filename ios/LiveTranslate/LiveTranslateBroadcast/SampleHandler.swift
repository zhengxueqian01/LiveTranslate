//
//  SampleHandler.swift
//  LiveTranslateBroadcast
//
//  Created by Xueqian Zheng on 2026/9/1.
//

import CoreMedia
import Foundation
import ReplayKit

enum BroadcastCaptureError: LocalizedError {
    case languageConfigurationMissing
    case audioQueueDropped
    case audioQueueTerminated

    var errorDescription: String? {
        switch self {
        case .languageConfigurationMissing:
            "未找到语言配置，请返回主 App 选择输入与输出语言后重新开始直播。"
        case .audioQueueDropped:
            "App 音频处理速度不足，启动或运行队列已满。"
        case .audioQueueTerminated:
            "App 音频队列已结束，无法继续接收音频。"
        }
    }
}

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private static let audioQueueCapacity = 32
    private static let audibleThreshold: Float = 0.001
    private static let silenceWarningDuration = Duration.seconds(3)
    private static let silenceCheckInterval = Duration.milliseconds(250)
    private static let silenceWarning =
        "连续 3 秒未检测到有效 App 音频；来源可能静音、受 DRM 保护或不允许捕获。"

    private let stateLock = NSLock()
    private let clock = ContinuousClock()
    private var clockOrigin: ContinuousClock.Instant?
    private var silenceState = SilenceMonitorState()
    private var captionCoordinator: BroadcastCaptionCoordinator?
    private var audioQueue: BoundedAsyncQueue<CapturedAudioSample>?
    private var startupTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var silenceMonitorTask: Task<Void, Never>?
    private var lastRecognizedText = ""
    private var isEnding = false
    private var didComplete = false

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        let task = Task { [weak self] in
            guard let self else { return }
            await startBroadcast()
        }
        let shouldCancel = stateLock.withLock {
            guard !didComplete, !isEnding else { return true }
            startupTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func startBroadcast() async {
        var startedCoordinator: BroadcastCaptionCoordinator?
        do {
            let captionStore = try CaptionStore()
            let failureCoordinator = BroadcastCaptionCoordinator(store: captionStore)
            try stateLock.withLock {
                guard !didComplete, !isEnding, !Task.isCancelled else {
                    throw CancellationError()
                }
                captionCoordinator = failureCoordinator
            }

            let configurationStore = try LanguageConfigurationStore()
            guard let configuration = configurationStore.load() else {
                throw BroadcastCaptureError.languageConfigurationMissing
            }
            let session = try await BroadcastStartupOrchestrator(
                preparer: .init(
                    checker: SystemBroadcastInstalledResourceChecker(),
                    translationClientBuilder: AppleTranslationClientBuilder()
                ),
                makeCoordinator: { [weak self] _, translator in
                    BroadcastCaptionCoordinator(
                        translator: translator,
                        store: captionStore,
                        onFailure: { [weak self] error in
                            self?.failBroadcast(error)
                        }
                    )
                }
            ).start(
                configuration: configuration,
                beforeBeginning: { [weak self] in
                    guard let self else {
                        throw CancellationError()
                    }
                    try self.stateLock.withLock {
                        guard !self.didComplete, !self.isEnding, !Task.isCancelled else {
                            throw CancellationError()
                        }
                    }
                },
                acceptAudio: { [weak self] session in
                    guard let self else {
                        throw CancellationError()
                    }
                    try self.acceptAudio(for: session)
                }
            )
            startedCoordinator = session.coordinator
        } catch is CancellationError {
            try? startedCoordinator?.stop()
            completeNormally()
        } catch {
            failBroadcast(error)
        }
    }

    override func broadcastPaused() {
        stateLock.withLock {
            guard !didComplete, !isEnding else { return }
            silenceState.pause()
        }
    }

    override func broadcastResumed() {
        let resources = stateLock.withLock { () -> (Bool, BroadcastCaptionCoordinator?) in
            guard !didComplete, !isEnding else { return (false, nil) }
            let shouldClear = silenceState.resume(at: elapsedLocked())
            return (shouldClear, captionCoordinator)
        }
        guard resources.0, let coordinator = resources.1 else { return }
        do {
            try coordinator.clearSilenceWarning()
        } catch {
            failBroadcast(error)
        }
    }

    override func broadcastFinished() {
        let resources = stateLock.withLock { () -> (
            queue: BoundedAsyncQueue<CapturedAudioSample>?,
            startupTask: Task<Void, Never>?,
            monitorTask: Task<Void, Never>?
        ) in
            guard !didComplete, !isEnding else { return (nil, nil, nil) }
            isEnding = true
            let startupTask = startupTask
            let monitorTask = silenceMonitorTask
            self.startupTask = nil
            silenceMonitorTask = nil
            return (audioQueue, startupTask, monitorTask)
        }
        resources.startupTask?.cancel()
        resources.monitorTask?.cancel()
        resources.queue?.finish()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .audioApp else { return }
        guard let queue = stateLock.withLock({
            didComplete || isEnding ? nil : audioQueue
        }) else {
            return
        }

        do {
            try queue.yield(CapturedAudioSample(buffer: sampleBuffer))
        } catch BoundedAsyncQueueError.dropped {
            failBroadcast(BroadcastCaptureError.audioQueueDropped)
        } catch BoundedAsyncQueueError.terminated {
            let shouldFail = stateLock.withLock { !didComplete && !isEnding }
            if shouldFail {
                failBroadcast(BroadcastCaptureError.audioQueueTerminated)
            }
        } catch {
            failBroadcast(error)
        }
    }

    private func acceptAudio(for session: BroadcastStartupSession) throws {
        let coordinator = session.coordinator
        try stateLock.withLock {
            guard !didComplete, !isEnding, !Task.isCancelled else {
                throw CancellationError()
            }
            captionCoordinator = coordinator
            clockOrigin = clock.now
            silenceState.start(at: .zero)
            lastRecognizedText = ""
        }
        try Task.checkCancellation()

        let queue = BoundedAsyncQueue<CapturedAudioSample>(
            capacity: Self.audioQueueCapacity
        )
        let sessionTask = Task { [weak self] in
            _ = await self?.runAudioSession(
                sourceLocaleIdentifier: session.sourceSpeechLocaleIdentifier,
                queue: queue,
                coordinator: coordinator
            )
        }
        let monitorTask = makeSilenceMonitor(coordinator: coordinator)
        let shouldCancel = stateLock.withLock {
            guard !didComplete, !isEnding, !Task.isCancelled else {
                return true
            }
            audioQueue = queue
            startupTask = nil
            audioTask = sessionTask
            silenceMonitorTask = monitorTask
            return false
        }
        if shouldCancel {
            queue.finish()
            sessionTask.cancel()
            monitorTask.cancel()
            throw CancellationError()
        }
    }

    private func runAudioSession(
        sourceLocaleIdentifier: String,
        queue: BoundedAsyncQueue<CapturedAudioSample>,
        coordinator: BroadcastCaptionCoordinator
    ) async {
        var pipeline: SpeechPipeline?
        do {
            let startedPipeline = try await SpeechPipeline.start(
                sourceLocaleIdentifier: sourceLocaleIdentifier,
                onText: { [weak self] text in
                    guard let self,
                          let timestamp = recordRecognizedText(text) else {
                        return
                    }
                    await coordinator.receiveRecognizedText(
                        text,
                        isFinal: false,
                        timestampMilliseconds: timestamp
                    )
                },
                onFailure: { [weak self] error in
                    self?.failBroadcast(error)
                }
            )
            pipeline = startedPipeline
            try coordinator.markRecognizing()

            for await sample in queue.stream {
                try Task.checkCancellation()
                let isAudible = try await startedPipeline.append(
                    sample,
                    audibleThreshold: Self.audibleThreshold
                )
                if isAudible {
                    recordAudibleEnergy(coordinator: coordinator)
                }
            }

            try Task.checkCancellation()
            try await startedPipeline.finish()
            pipeline = nil
            if let finalUpdate = finalRecognizedText() {
                await coordinator.receiveRecognizedText(
                    finalUpdate.text,
                    isFinal: true,
                    timestampMilliseconds: finalUpdate.timestampMilliseconds
                )
            }
            try await coordinator.flushPendingTranslations()
            try coordinator.stop()
            completeNormally()
        } catch is CancellationError {
            if let pipeline {
                await finishAfterTermination(pipeline)
            }
        } catch {
            failBroadcast(error)
            if let pipeline {
                await finishAfterTermination(pipeline)
            }
        }
    }

    private func makeSilenceMonitor(
        coordinator: BroadcastCaptionCoordinator
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.silenceCheckInterval)
                } catch {
                    return
                }
                let shouldReport = stateLock.withLock {
                    guard !didComplete, !isEnding else { return false }
                    return silenceState.takeWarningIfDue(
                        at: elapsedLocked(),
                        after: Self.silenceWarningDuration
                    )
                }
                guard shouldReport else { continue }
                do {
                    try coordinator.reportSilence(message: Self.silenceWarning)
                } catch {
                    failBroadcast(error)
                    return
                }
            }
        }
    }

    private func recordAudibleEnergy(
        coordinator: BroadcastCaptionCoordinator
    ) {
        let shouldClear = stateLock.withLock {
            guard !didComplete, !isEnding else { return false }
            return silenceState.markAudible(at: elapsedLocked())
        }
        guard shouldClear else { return }
        do {
            try coordinator.clearSilenceWarning()
        } catch {
            failBroadcast(error)
        }
    }

    private func elapsedLocked() -> Duration {
        guard let clockOrigin else { return .zero }
        return clockOrigin.duration(to: clock.now)
    }

    private func recordRecognizedText(_ text: String) -> UInt64? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return nil }
        return stateLock.withLock {
            guard !didComplete else { return nil }
            lastRecognizedText = normalizedText
            return elapsedMillisecondsLocked()
        }
    }

    private func finalRecognizedText() -> (
        text: String,
        timestampMilliseconds: UInt64
    )? {
        stateLock.withLock {
            guard !lastRecognizedText.isEmpty else { return nil }
            return (lastRecognizedText, elapsedMillisecondsLocked())
        }
    }

    private func elapsedMillisecondsLocked() -> UInt64 {
        let components = elapsedLocked().components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return UInt64.max }
        let attoseconds = UInt64(max(components.attoseconds, 0))
        let fractionalMilliseconds = attoseconds / 1_000_000_000_000_000
        let (result, additionOverflow) = milliseconds.addingReportingOverflow(
            fractionalMilliseconds
        )
        return additionOverflow ? UInt64.max : result
    }

    private func completeNormally() {
        let tasks = stateLock.withLock { () -> (
            startupTask: Task<Void, Never>?,
            monitorTask: Task<Void, Never>?
        ) in
            guard !didComplete else { return (nil, nil) }
            didComplete = true
            isEnding = true
            let startupTask = startupTask
            let monitorTask = silenceMonitorTask
            self.startupTask = nil
            silenceMonitorTask = nil
            audioQueue = nil
            audioTask = nil
            return (startupTask, monitorTask)
        }
        tasks.startupTask?.cancel()
        tasks.monitorTask?.cancel()
    }

    private func failBroadcast(_ error: any Error) {
        let resources = stateLock.withLock { () -> (
            queue: BoundedAsyncQueue<CapturedAudioSample>?,
            startupTask: Task<Void, Never>?,
            audioTask: Task<Void, Never>?,
            monitorTask: Task<Void, Never>?,
            coordinator: BroadcastCaptionCoordinator?
        )? in
            guard !didComplete else { return nil }
            didComplete = true
            isEnding = true
            let resources = (
                audioQueue,
                startupTask,
                audioTask,
                silenceMonitorTask,
                captionCoordinator
            )
            audioQueue = nil
            startupTask = nil
            audioTask = nil
            silenceMonitorTask = nil
            return resources
        }
        guard let resources else { return }

        resources.queue?.finish()
        resources.startupTask?.cancel()
        resources.audioTask?.cancel()
        resources.monitorTask?.cancel()
        do {
            try resources.coordinator?.fail(message: error.localizedDescription)
        } catch {
            // The original failure remains the error reported to ReplayKit.
        }
        finishBroadcastWithError(error as NSError)
    }

    private func finishAfterTermination(_ pipeline: SpeechPipeline) async {
        do {
            try await pipeline.finish()
        } catch {
            // A primary terminal error has already been reported by this point.
        }
    }
}
