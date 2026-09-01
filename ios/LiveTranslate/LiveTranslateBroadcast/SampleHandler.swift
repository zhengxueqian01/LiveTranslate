//
//  SampleHandler.swift
//  LiveTranslateBroadcast
//
//  Created by Xueqian Zheng on 2026/9/1.
//

import AVFAudio
import CoreMedia
import Foundation
import ReplayKit

enum BroadcastCaptureError: LocalizedError {
    case sourceLanguageMissing

    var errorDescription: String? {
        switch self {
        case .sourceLanguageMissing:
            "未找到来源语言，请返回主 App 选择语言后重新开始直播。"
        }
    }
}

private final class CaptionStatusWriter: @unchecked Sendable {
    private let store: CaptionStore
    private let lock = NSLock()

    init() throws {
        store = try CaptionStore()
    }

    func write(
        sourceText: String? = nil,
        phase: SessionPhase,
        errorMessage: String?
    ) throws {
        try lock.withLock {
            let previous = try store.load()
            let snapshot = CaptionSnapshot(
                revision: (previous?.revision ?? 0) + 1,
                sourceText: sourceText ?? previous?.sourceText ?? "",
                translatedText: previous?.translatedText ?? "",
                phase: phase,
                errorMessage: errorMessage,
                updatedAt: Date()
            )
            try store.save(snapshot)
        }
    }
}

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private static let audibleThreshold: Float = 0.001
    private static let silenceWarningDuration: TimeInterval = 3
    private static let silenceWarning =
        "连续 3 秒未检测到有效 App 音频；来源可能静音、受 DRM 保护或不允许捕获。"

    private let stateLock = NSLock()
    private var pipeline: SpeechPipeline?
    private var statusWriter: CaptionStatusWriter?
    private var startTask: Task<Void, Never>?
    private var silenceMonitorTask: Task<Void, Never>?
    private var lastAudibleDate: Date?
    private var didReportSilence = false
    private var didFinish = false

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        do {
            let writer = try CaptionStatusWriter()
            stateLock.withLock {
                statusWriter = writer
            }
            let sourceStore = try SourceLanguageStore()
            guard let source = sourceStore.load() else {
                throw BroadcastCaptureError.sourceLanguageMissing
            }
            try writer.write(phase: .broadcasting, errorMessage: nil)

            let task = Task { [weak self] in
                do {
                    let createdPipeline = try await SpeechPipeline.start(source: source) { [weak self] text in
                        self?.handleRecognizedText(text)
                    }
                    guard let self else {
                        await createdPipeline.finish()
                        return
                    }
                    let accepted = stateLock.withLock {
                        guard !didFinish else { return false }
                        pipeline = createdPipeline
                        return true
                    }
                    if accepted {
                        startSilenceMonitor()
                        do {
                            try writer.write(phase: .recognizing, errorMessage: nil)
                        } catch {
                            failBroadcast(error)
                        }
                    } else {
                        await createdPipeline.finish()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.failBroadcast(error)
                }
            }
            stateLock.withLock {
                if didFinish {
                    task.cancel()
                } else {
                    startTask = task
                }
            }
        } catch {
            failBroadcast(error)
        }
    }

    override func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
    }

    override func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
    }

    override func broadcastFinished() {
        let resources = stateLock.withLock { () -> (Bool, Task<Void, Never>?, Task<Void, Never>?, SpeechPipeline?, CaptionStatusWriter?) in
            let shouldWriteStopped = !didFinish
            didFinish = true
            let resources = (shouldWriteStopped, startTask, silenceMonitorTask, pipeline, statusWriter)
            startTask = nil
            silenceMonitorTask = nil
            pipeline = nil
            return resources
        }
        resources.1?.cancel()
        resources.2?.cancel()
        if resources.0, let writer = resources.4 {
            try? writer.write(phase: .stopped, errorMessage: nil)
        }
        if let pipeline = resources.3 {
            Task {
                await pipeline.finish()
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .audioApp:
            processAppAudio(sampleBuffer)
        case .audioMic, .video:
            return
        @unknown default:
            return
        }
    }

    private func processAppAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let pipeline = stateLock.withLock({ didFinish ? nil : pipeline }) else {
            return
        }
        do {
            let buffer = try pipeline.append(sampleBuffer)
            updateSilenceState(
                hasAudibleEnergy: AudioPCMConverter.hasAudibleEnergy(
                    buffer,
                    threshold: Self.audibleThreshold
                )
            )
        } catch {
            failBroadcast(error)
        }
    }

    private func startSilenceMonitor() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                self?.reportSilenceIfNeeded()
            }
        }
        stateLock.withLock {
            guard !didFinish else {
                task.cancel()
                return
            }
            lastAudibleDate = Date()
            silenceMonitorTask = task
        }
    }

    private func updateSilenceState(hasAudibleEnergy: Bool) {
        guard hasAudibleEnergy else { return }
        let writerToClear = stateLock.withLock { () -> CaptionStatusWriter? in
            guard !didFinish else { return nil }
            lastAudibleDate = Date()
            guard didReportSilence else { return nil }
            didReportSilence = false
            return statusWriter
        }
        guard let writerToClear else { return }
        do {
            try writerToClear.write(phase: .recognizing, errorMessage: nil)
        } catch {
            failBroadcast(error)
        }
    }

    private func reportSilenceIfNeeded() {
        let writerToNotify = stateLock.withLock { () -> CaptionStatusWriter? in
            guard !didFinish,
                  !didReportSilence,
                  let lastAudibleDate,
                  Date().timeIntervalSince(lastAudibleDate) >= Self.silenceWarningDuration else {
                return nil
            }
            didReportSilence = true
            return statusWriter
        }
        guard let writerToNotify else { return }
        do {
            try writerToNotify.write(
                phase: .recognizing,
                errorMessage: Self.silenceWarning
            )
        } catch {
            failBroadcast(error)
        }
    }

    private func handleRecognizedText(_ text: String) {
        guard let writer = stateLock.withLock({ didFinish ? nil : statusWriter }) else {
            return
        }
        do {
            try writer.write(
                sourceText: text,
                phase: .recognizing,
                errorMessage: nil
            )
        } catch {
            failBroadcast(error)
        }
    }

    private func failBroadcast(_ error: any Error) {
        let resources = stateLock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, SpeechPipeline?, CaptionStatusWriter?)? in
            guard !didFinish else { return nil }
            didFinish = true
            let resources = (startTask, silenceMonitorTask, pipeline, statusWriter)
            startTask = nil
            silenceMonitorTask = nil
            pipeline = nil
            return resources
        }
        guard let resources else { return }

        resources.0?.cancel()
        resources.1?.cancel()
        try? resources.3?.write(
            phase: .failed,
            errorMessage: error.localizedDescription
        )
        if let pipeline = resources.2 {
            Task {
                await pipeline.finish()
            }
        }
        finishBroadcastWithError(error as NSError)
    }
}
